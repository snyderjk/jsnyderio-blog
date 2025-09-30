+++
title = "AWS Serverless Color Palette Generator - Part 1"
date = 2025-09-28
[taxonomies]
tags = ["AWS", "serverless", "IaC", "Terraform"]
+++

# Building a Color Palette Generator: Part 1 - S3 Event Fan-out with Terraform

I'm building a serverless application that generates color palettes from uploaded images. The architecture is straightforward: users upload an image to S3, which triggers two separate processing pipelines - one to generate a color palette and another to create a thumbnail. Both need to process the same image independently.

This post covers the first phase: wiring up S3 events to push messages into multiple SQS queues when a file gets uploaded.

## The Problem: S3 Won't Let You Double-Dip

My initial Terraform looked like this:

```hcl
resource "aws_s3_bucket_notification" "bucket" {
  bucket = aws_s3_bucket.bucket.id
  
  queue {
    queue_arn = aws_sqs_queue.palette.arn
    events    = ["s3:ObjectCreated:*"]
  }
  
  queue {
    queue_arn = aws_sqs_queue.thumbnail.arn
    events    = ["s3:ObjectCreated:*"]
  }
}
```

Seems reasonable, right? Wrong. S3 immediately rejected this with:

```
Error: Configurations overlap. Configurations on the same bucket 
cannot share a common event type.
```

S3 bucket notifications don't support multiple targets for the same event unless you use filters (like `filter_prefix` or `filter_suffix`) to separate them. Since I want both queues to receive messages for *every* uploaded file, filters won't help.

## The Solution: EventBridge Fan-out

EventBridge solves this. Instead of S3 notifying queues directly, you enable EventBridge on the bucket, create an EventBridge rule that matches S3 object creation events, and route those events to multiple targets.

Here's the complete Terraform:

```hcl
# S3 Bucket
resource "aws_s3_bucket" "bucket" {
  bucket        = var.bucket_name
  force_destroy = true
  
  tags = {
    Project = "serverless-color-palette"
    Owner   = "terraform"
  }
}

# Security configurations
resource "aws_s3_bucket_ownership_controls" "bucket" {
  bucket = aws_s3_bucket.bucket.id
  
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "bucket" {
  bucket                  = aws_s3_bucket.bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SQS Queues
resource "aws_sqs_queue" "palette" {
  name                       = "${var.bucket_name}-palette-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 1209600
}

resource "aws_sqs_queue" "thumbnail" {
  name                       = "${var.bucket_name}-thumbnail-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 1209600
}

# Enable EventBridge on the S3 bucket
resource "aws_s3_bucket_notification" "bucket" {
  bucket      = aws_s3_bucket.bucket.id
  eventbridge = true
}

# EventBridge Rule to catch S3 object creation events
resource "aws_cloudwatch_event_rule" "s3_object_created" {
  name        = "${var.bucket_name}-object-created"
  description = "Trigger on S3 object creation"
  
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.bucket.id]
      }
    }
  })
}

# Route events to both queues
resource "aws_cloudwatch_event_target" "palette_queue" {
  rule      = aws_cloudwatch_event_rule.s3_object_created.name
  target_id = "palette-queue"
  arn       = aws_sqs_queue.palette.arn
}

resource "aws_cloudwatch_event_target" "thumbnail_queue" {
  rule      = aws_cloudwatch_event_rule.s3_object_created.name
  target_id = "thumbnail-queue"
  arn       = aws_sqs_queue.thumbnail.arn
}

# Queue policies to allow EventBridge to send messages
resource "aws_sqs_queue_policy" "palette" {
  queue_url = aws_sqs_queue.palette.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "SQS:SendMessage"
      Resource = aws_sqs_queue.palette.arn
    }]
  })
}

resource "aws_sqs_queue_policy" "thumbnail" {
  queue_url = aws_sqs_queue.thumbnail.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "SQS:SendMessage"
      Resource = aws_sqs_queue.thumbnail.arn
    }]
  })
}
```

## How It Works

1. A file gets uploaded to the S3 bucket
2. S3 sends an event to EventBridge (because `eventbridge = true`)
3. EventBridge evaluates the event against all rules
4. Our rule matches (it's an "Object Created" event from our bucket)
5. EventBridge sends the event to both SQS queues simultaneously
6. Each queue receives an identical message with the S3 event details

## Why EventBridge Over SNS?

SNS topic fan-out is the other common pattern for this. Both work fine, but I went with EventBridge because:

- **One less resource to create** - EventBridge is just `eventbridge = true` on the bucket, while SNS requires creating and managing a topic
- **Better for complex routing later** - If I need sophisticated event pattern matching or want to route to services beyond SQS (Step Functions, API destinations, etc.), EventBridge handles that more naturally

SNS has its own advantages though - simpler mental model, subscription-level message filtering, and lower latency. For basic S3 → multiple SQS fan-out, they're functionally equivalent. Pick whichever fits your existing architecture.

## Next Steps

Now that the event plumbing works, the next phase is building the actual processors - Lambda functions that pull messages from these queues and generate the color palette and thumbnail. I'll cover that in part 2.

The complete code is available on [https://github.com/snyderjk/aws-color-palette-generator]|Github

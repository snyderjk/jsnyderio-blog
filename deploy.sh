#!/bin/bash

zola build

rm -rf /tmp/zola-deploy
mkdir /tmp/zola-deploy
cp -r public/* /tmp/zola-deploy

git worktree add /tmp/gh-pages gh-pages
cp -r /tmp/zola-deploy/* /tmp/gh-pages
cd /tmp/gh-pages
git add .
git commit -m "Deploy $(date +%F\|%T)"
git push origin gh-pages
cd -
git worktree remove /tmp/gh-pages
rm -rf public/

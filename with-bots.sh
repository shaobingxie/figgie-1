#!/bin/bash
set -eux

SERVER=./server.exe
BOT=./bot.exe

"$SERVER" -length-of-round 1m -enable-chat true -log-level Debug &
victims=$!
trap 'kill $victims' EXIT
sleep 1
for ty in sell chaos count
do
  "$BOT" $ty -server localhost:58828 -log-level Debug \
    2>&1 | sed -re "s/^/$ty /" &
  victims="$victims $!"
  sleep 3
done
wait

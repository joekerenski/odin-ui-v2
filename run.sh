#!/bin/sh
cd "$(dirname "$0")"
odin run app -out:graph -o:speed "$@"

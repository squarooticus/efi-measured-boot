#! /bin/bash

buildre() {
    local IFS='|'
    echo "${*//\//\\\/}"
}

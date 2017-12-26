#!/bin/sh

set -e

mkdir -p src
cp -r text/* src

echo "[Introduction](introduction.md)" > src/SUMMARY.md
echo "" >> src/SUMMARY.md

for fn in $(ls text | sort)
do
    f="text/$fn"
    if [ -f "$f/README.md" ]; then
        echo "- [$(basename $fn "/")]($fn/README.md)" >> src/SUMMARY.md
        for subfn in $(ls -1 $f/*-*.md | sort); do
            echo "    - [$(basename "$subfn" ".md" | cut -d- -f 2-)]($fn/$(basename "$subfn"))" >> src/SUMMARY.md
        done
    elif [ -f "$f" ]; then
        echo "- [$(basename $fn ".md")]($fn)" >> src/SUMMARY.md
    fi
done

cp README.md src/introduction.md

mdbook build

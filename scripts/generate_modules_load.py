#!/usr/bin/env python3
import os
import sys

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <modules.dep> <modules.load>")
    sys.exit(1)

depfile = sys.argv[1]
outfile = sys.argv[2]

modules = {}
with open(depfile) as f:
    for line in f:
        mod, *deps = line.strip().split(":")
        mod = os.path.basename(mod)
        deps = [os.path.basename(d) for d in deps[0].split() if d]
        modules[mod] = deps

visited = set()
order = []

def visit(m):
    if m in visited:
        return
    for dep in modules.get(m, []):
        visit(dep)
    visited.add(m)
    order.append(m)

for m in modules:
    visit(m)

with open(outfile, "w") as f:
    for m in order:
        f.write(m + "\n")
        
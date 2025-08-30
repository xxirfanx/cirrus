#!/usr/bin/env python3
import os
import sys

if len(sys.argv) != 2:
    print(f"Usage: {sys.argv[0]} <modules.dep>")
    sys.exit(1)

depfile = sys.argv[1]

with open(depfile, "r") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    line = line.strip()
    if not line:
        new_lines.append("\n")
        continue

    left, right = (line.split(":", 1) + [""])[:2]
    left_ko = os.path.basename(left.strip())
    deps = [os.path.basename(x) for x in right.strip().split()] if right.strip() else []

    newline = f"/system/lib/modules/{left_ko}:"
    if deps:
        newline += " " + " ".join(f"/system/lib/modules/{d}" for d in deps)
    new_lines.append(newline + "\n")

with open(depfile, "w") as f:
    f.writelines(new_lines)

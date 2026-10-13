#!/usr/bin/env python3
"""
inputcheck.py - will every EA input comment actually be READABLE?

WHY THIS EXISTS
===============

An MQL `input` line has this shape:

    input int SenderPort = 5555;   // SenderPort - the sender's EventsPort

and the text after `//` is what MetaTrader prints in the Inputs tab of the EA
properties dialog. That column is a fixed width. Anything longer is simply
CUT OFF - there is no ellipsis, no tooltip, no way to see the rest without
opening the .mq4.

The failure is quiet and expensive. The operator reads a sentence that stops
mid-word, guesses at the meaning, and configures the EA wrongly - and the
person who wrote it never sees the problem, because in the SOURCE the line is
complete.

So the comment is part of the user interface, and it has a hard budget.

WHAT IT CHECKS
==============

  1. Length. The comment must fit CP_INPUT_COMMENT_MAX characters.
  2. The `Name - ` prefix. MetaTrader's own convention, and it is what makes a
     truncated line still identifiable.
  3. That no comment repeats the parameter name in a way that wastes the
     budget (e.g. "SenderPort - the SenderPort port").

Run:  python tools/inputcheck.py            (all files)
      python tools/inputcheck.py --verbose  (also list the ones that pass)
"""

import io
import os
import re
import sys

# --- The budget -------------------------------------------------------------
#
# Measured, not guessed: at the default dialog width the column clips just past
# the 56th character. 54 leaves a little room for a wider font or a different
# DPI, because the cost of being one character short is nothing and the cost of
# being one character over is a sentence that ends mid-word.
CP_INPUT_COMMENT_MAX = 54

FILES = [
    "src/Experts/CopierSender.mq4",
    "src/Experts/CopierReceiver.mq4",
]

# `input <type> <Name> = <default>;   // comment`
INPUT_RE = re.compile(r"^\s*input\s+.+?;\s*//\s*(?P<comment>.*?)\s*$")


def comment_of(line):
    m = INPUT_RE.match(line)
    return m.group("comment") if m else None


def check_file(path):
    problems = []
    passes = []
    with io.open(path, encoding="utf-8", errors="replace") as f:
        for n, raw in enumerate(f, 1):
            comment = comment_of(raw)
            if comment is None:
                continue
            # the parameter name is the token just before the '='
            name = re.search(r"input\s+\S+\s+(\w+)\s*=", raw)
            name = name.group(1) if name else ""

            if len(comment) > CP_INPUT_COMMENT_MAX:
                problems.append((n, name, len(comment), comment,
                                 "too long by %d" % (len(comment) - CP_INPUT_COMMENT_MAX)))
                continue

            if not comment.startswith(name + " - ") and name:
                # A DELIBERATE short alias is fine and sometimes necessary:
                # RequirePositionFillWithinSeconds does not fit in the column
                # at all, so its label is "FillWithinSeconds - ...". What is
                # NOT fine is a label naming a different parameter, which is
                # what a copy-paste between input blocks leaves behind.
                prefix = comment.split(" - ", 1)[0] if " - " in comment else ""
                if prefix.lower() not in name.lower():
                    problems.append((n, name, len(comment), comment,
                                     "label '%s' does not match parameter '%s'"
                                     % (prefix, name)))
                    continue

            body = comment[len(name) + 3:] if name else comment
            if name and body.lower().startswith(name.lower()):
                problems.append((n, name, len(comment), comment,
                                 "repeats the parameter name - wasted budget"))
                continue

            passes.append((n, name, len(comment), comment))

    return problems, passes


def main():
    verbose = "--verbose" in sys.argv
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    total_bad = 0
    total_pass = 0

    for rel in FILES:
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            print("  MISSING  %s" % rel)
            total_bad += 1
            continue

        problems, passes = check_file(path)
        total_bad += len(problems)
        total_pass += len(passes)

        head = "  %s" % rel
        print(head)
        if not problems:
            print("      all %d comment(s) fit within %d chars"
                  % (len(passes), CP_INPUT_COMMENT_MAX))
        for n, name, ln, comment, why in problems:
            print("      line %-5d %-3d chars  (%s)" % (n, ln, why))
            print("        %s" % comment)
        if verbose:
            for n, name, ln, comment in passes:
                print("      ok  %-3d chars  %s" % (ln, comment))
        print()

    print("  %d comment(s) checked, %d problem(s)" % (total_pass + total_bad, total_bad))
    if total_bad:
        print()
        print("  A comment that does not fit is not a style issue: MetaTrader")
        print("  cuts it off in the Inputs dialog with no indication that there")
        print("  was more. The operator then configures the EA from a sentence")
        print("  that ends mid-word.")
    return 1 if total_bad else 0


if __name__ == "__main__":
    sys.exit(main())

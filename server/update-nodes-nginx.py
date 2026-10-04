#!/usr/bin/env python3
"""Idempotently extend the exact enana API allowlist, preserving other hosts."""
import pathlib, sys

def update(text):
    anchor='|email/status|email/send'
    addition='|servers/shares|servers/share'
    if addition in text:
        if text.count(anchor+addition)!=1:
            raise ValueError('unexpected existing node allowlist')
        return text
    if text.count(anchor)!=1:
        raise ValueError('unexpected enana API allowlist')
    return text.replace(anchor,anchor+addition)

if __name__=='__main__':
    source,target=map(pathlib.Path,sys.argv[1:3])
    target.write_text(update(source.read_text()))

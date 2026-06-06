// Objective-C declarations exposed to the Snappet app target's Swift code.
// Kept minimal: the AVFoundation NSException bridge (see ObjCException.h) + zlib
// (gzip inflate for the Kilter hosted-catalog download — KilterAuroraSync.swift).
#import "Services/ObjCException.h"
#import <zlib.h>

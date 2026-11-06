// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Finder's backgroundImageAlias uses a Carbon alias record, not a bookmark.
#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
int main(int argc, const char **argv) {
 if(argc!=3) return 2;
 FSRef ref; AliasHandle alias=NULL;
 if(FSPathMakeRef((const UInt8 *)argv[1], &ref, NULL)!=noErr) return 1;
 if(FSNewAlias(NULL,&ref,&alias)!=noErr) return 1;
 HLock((Handle)alias);
 NSData *data=[NSData dataWithBytes:*alias length:GetHandleSize((Handle)alias)];
 BOOL ok=[data writeToFile:@(argv[2]) atomically:YES];
 HUnlock((Handle)alias); DisposeHandle((Handle)alias);
 return ok?0:1;
}

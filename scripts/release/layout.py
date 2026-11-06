#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Write a small, single-leaf Finder store; no Finder automation or dependencies.
Format reference: https://metacpan.org/dist/Mac-Finder-DSStore/view/DSStoreFormat.pod
All buddy offsets are relative to byte 4. Only five fixed records are needed.
"""
import pathlib, plistlib, struct, sys
mount=pathlib.Path(sys.argv[1]); alias=pathlib.Path(sys.argv[2]).read_bytes()
def ints(*n): return struct.pack('>'+'I'*len(n),*n)
def blob(name,code,value):
    encoded=name.encode('utf-16be')
    return ints(len(encoded)//2)+encoded+code.encode()+b'blob'+ints(len(value))+value
window={'ShowStatusBar':False,'ShowToolbar':False,'ShowSidebar':False,'ShowPathbar':False,'ShowTabView':False,'WindowBounds':'{{80, 80}, {660, 440}}','ContainerShowSidebar':False}
icons={'viewOptionsVersion':1,'backgroundType':2,'backgroundImageAlias':alias,'iconSize':100.0,'textSize':13.0,'gridSpacing':100.0,'gridOffsetX':0.0,'gridOffsetY':0.0,'arrangeBy':'none','labelOnBottom':True,'showIconPreview':True,'showItemInfo':False}
records=[blob('.', 'bwsp',plistlib.dumps(window,fmt=plistlib.FMT_BINARY)),blob('.', 'icvp',plistlib.dumps(icons,fmt=plistlib.FMT_BINARY)),ints(1)+'.'.encode('utf-16be')+b'vSrnlong'+ints(1),ints(1)+'.'.encode('utf-16be')+b'vstltypeicnv',blob('Airc.app','Iloc',ints(180,225,0xffffffff,0xffff0000)),blob('Applications','Iloc',ints(480,225,0xffffffff,0xffff0000))]
# Buddy blocks: header=0/32, tree descriptor=32/32, allocator=2048/2048,
# leaf=4096/4096. Free lists cover all remaining space without overlaps.
free=b''
for power in range(32):
    free+=ints(1,1<<power) if power in list(range(6,11))+list(range(13,31)) else ints(0)
allocator=ints(3,0)+ints(2048|11,32|5,4096|12)+bytes(253*4)+ints(1)+b'\x04DSDB'+ints(1)+free
image=bytearray(8196)
image[:36]=struct.pack('>I4sIII16s',1,b'Bud1',2048,len(allocator),2048,bytes(16))
image[36:56]=ints(2,0,len(records),1,4096)
image[2052:2052+len(allocator)]=allocator
leaf=ints(0,len(records))+b''.join(records)
assert len(leaf)<=4096
image[4100:4100+len(leaf)]=leaf
(mount/'.DS_Store').write_bytes(image)

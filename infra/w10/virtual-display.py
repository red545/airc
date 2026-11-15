#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Test-only CoreGraphics SPI via Objective-C runtime; no packages or app linkage."""
import ctypes as C
import json
import sys
import time


class Point(C.Structure):
    _fields_ = [('x', C.c_double), ('y', C.c_double)]


class Rect(C.Structure):
    _fields_ = [('origin', Point), ('size', Point)]


def main():
    C.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation')
    cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    objc = C.CDLL('/usr/lib/libobjc.A.dylib')
    system = C.CDLL('/usr/lib/libSystem.B.dylib')
    ptr, uint = C.c_void_p, C.c_uint32
    objc.objc_getClass.argtypes = [C.c_char_p]
    objc.objc_getClass.restype = ptr
    objc.sel_registerName.argtypes = [C.c_char_p]
    objc.sel_registerName.restype = ptr
    def send(obj, selector, result=ptr, types=(), args=()):
        fn = C.CFUNCTYPE(result, ptr, ptr, *types)(('objc_msgSend', objc))
        return fn(obj, objc.sel_registerName(selector.encode()), *args)
    def new(name):
        cls = objc.objc_getClass(name.encode())
        if not cls:
            raise RuntimeError('FAIL-ENV: missing SPI class ' + name)
        return send(send(cls, 'alloc'), 'init')
    def setval(obj, key, value, kind=uint):
        send(obj, 'set' + key[0].upper() + key[1:] + ':', None, (kind,), (value,))
    cg.CGMainDisplayID.restype = uint
    cg.CGDisplayBounds.argtypes = [uint]
    cg.CGDisplayBounds.restype = Rect
    cg.CGDisplayIsOnline.argtypes = [uint]
    cg.CGDisplayIsOnline.restype = uint
    cg.CGBeginDisplayConfiguration.argtypes = [C.POINTER(ptr)]
    cg.CGConfigureDisplayOrigin.argtypes = [ptr, uint, C.c_int32, C.c_int32]
    cg.CGCompleteDisplayConfiguration.argtypes = [ptr, C.c_int32]
    cg.CGCancelDisplayConfiguration.argtypes = [ptr]
    system.dispatch_get_global_queue.argtypes = [C.c_long, C.c_ulong]
    system.dispatch_get_global_queue.restype = ptr
    pool = new('NSAutoreleasePool')
    display = descriptor = settings = mode = None
    display_id = 0
    try:
        descriptor = new('CGVirtualDisplayDescriptor')
        name = send(objc.objc_getClass(b'NSString'), 'stringWithUTF8String:', ptr, (C.c_char_p,), (b'Airc W10 synthetic display',))
        setval(descriptor, 'name', name, ptr)
        for key, value in dict(maxPixelsWide=1920, maxPixelsHigh=1080, vendorID=505, productID=10, serialNum=1010, serialNumber=1010).items():
            setval(descriptor, key, value)
        for key, xy in dict(sizeInMillimeters=(508, 286), redPrimary=(.64, .33), greenPrimary=(.30, .60), bluePrimary=(.15, .06), whitePoint=(.3127, .3290)).items():
            setval(descriptor, key, Point(*xy), Point)
        setval(descriptor, 'queue', system.dispatch_get_global_queue(0, 0), ptr)
        display = send(send(objc.objc_getClass(b'CGVirtualDisplay'), 'alloc'), 'initWithDescriptor:', ptr, (ptr,), (descriptor,))
        if not display:
            raise RuntimeError('FAIL-ENV: virtual display creation refused')
        mode = send(send(objc.objc_getClass(b'CGVirtualDisplayMode'), 'alloc'), 'initWithWidth:height:refreshRate:', ptr, (uint, uint, C.c_double), (1920, 1080, 60))
        settings = new('CGVirtualDisplaySettings')
        modes = send(objc.objc_getClass(b'NSArray'), 'arrayWithObject:', ptr, (ptr,), (mode,))
        setval(settings, 'modes', modes, ptr)
        setval(settings, 'hiDPI', 0)
        if not send(display, 'applySettings:', C.c_bool, (ptr,), (settings,)):
            raise RuntimeError('FAIL-ENV: virtual display mode refused')
        display_id = send(display, 'displayID', uint)
        time.sleep(2)
        main_id = cg.CGMainDisplayID()
        main_bounds = cg.CGDisplayBounds(main_id)
        config = ptr()
        error = cg.CGBeginDisplayConfiguration(C.byref(config))
        if error == 0:
            error = cg.CGConfigureDisplayOrigin(config, display_id, int(main_bounds.origin.x + main_bounds.size.x), 0)
            if error == 0:
                error = cg.CGCompleteDisplayConfiguration(config, 0)  # app-only arrangement; expires with the helper
            else:
                cg.CGCancelDisplayConfiguration(config)
        if error:
            raise RuntimeError('FAIL-ENV: display configuration error=' + str(error))
        time.sleep(2)
        b = cg.CGDisplayBounds(display_id)
        print(json.dumps(dict(displayID=display_id, mainDisplayID=main_id, x=b.origin.x, y=b.origin.y, width=b.size.x, height=b.size.y)), flush=True)
        sys.stdin.buffer.read(1)  # EOF when the parent exits; no detached display server.
    finally:
        for obj in (display, settings, mode, descriptor):
            if obj:
                send(obj, 'release', None)
        send(pool, 'drain', None)
        time.sleep(2)
        removed = not display_id or not cg.CGDisplayIsOnline(display_id)
        print('released_online=' + str(not removed).lower(), flush=True)
    return 0  # WindowServer may defer removal until process exit; the parent verifies it.


if __name__ == '__main__':
    sys.exit(main())

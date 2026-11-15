ObjC.import('AppKit'); ObjC.import('CoreGraphics');
function run(args) {
 var pid=Number(args[0]); var app=$.NSRunningApplication.runningApplicationWithProcessIdentifier(pid);
 if(app.isNil() || app.isTerminated) return JSON.stringify({registered:false,active:false,windows:[],pid:pid});
 if(args[1]==='activate') app.activateWithOptions(3);
 if(args[1]==='hover') $.CGWarpMouseCursorPosition($.CGPointMake(80,1));
 if(args[1]==='away') $.CGWarpMouseCursorPosition($.CGPointMake(500,400));
 var list=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1,0)));
 var screen=$.NSScreen.mainScreen.frame;
 return JSON.stringify({registered:true,active:app.isActive,screen:{width:screen.size.width,height:screen.size.height},windows:list.filter(function(w){return w.kCGWindowOwnerPID===pid;}).map(function(w){return {id:w.kCGWindowNumber,layer:w.kCGWindowLayer,bounds:w.kCGWindowBounds};})});
}

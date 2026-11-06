// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#import <AppKit/AppKit.h>

#define AIRC_EXPORT __attribute__((visibility("default")))

NS_ASSUME_NONNULL_BEGIN

@class AircEngine;
@class AircProfile;
@class AircTab;
@class AircWindow;

@protocol AircEngineDelegate <NSObject>
- (void)engineDidStart;
- (void)engineWillShutDown;
- (void)engineQuitCancelled;
- (nullable AircWindow*)engineWindowForNewBrowserOfProfile:(AircProfile*)profile
                                                        type:(NSString*)type;
- (void)engine:(AircEngine*)engine
    permissionRequest:(NSDictionary<NSString*, id>*)request
                  tab:(AircTab*)tab;
- (void)engine:(AircEngine*)engine permissionRequestDismissed:(NSString*)requestId;
- (void)engine:(AircEngine*)engine
    extensionSidePanel:(NSDictionary<NSString*, id>*)panel
                   tab:(AircTab*)tab;
- (BOOL)engine:(AircEngine*)engine
    extensionActionPopup:(NSDictionary<NSString*, id>*)popup
                     tab:(AircTab*)tab;
- (BOOL)engine:(AircEngine*)engine
    extensionActionShortcut:(NSDictionary<NSString*, id>*)shortcut
                        tab:(AircTab*)tab;
- (BOOL)engineIsReservedKeyEvent:(NSEvent*)event;
- (BOOL)engineIsReservedKey:(NSString*)key
               unshiftedKey:(NSString*)unshiftedKey
                  modifiers:(NSEventModifierFlags)modifiers;
- (void)engine:(AircEngine*)engine
    extensionInstallPrompt:(NSDictionary<NSString*, id>*)prompt
                   profile:(AircProfile*)profile
                       tab:(nullable AircTab*)tab;
- (void)engine:(AircEngine*)engine
    extensionInstallFailed:(NSString*)message
                       tab:(nullable AircTab*)tab;
- (void)engine:(AircEngine*)engine
    deviceChooser:(NSDictionary<NSString*, id>*)chooser
              tab:(AircTab*)tab;
- (void)engine:(AircEngine*)engine
    castDialog:(NSDictionary<NSString*, id>*)dialog
           tab:(AircTab*)tab;
- (void)engine:(AircEngine*)engine
    castRoutes:(NSArray<NSDictionary<NSString*, NSString*>*>*)routes
       profile:(AircProfile*)profile;
@optional
// Synchronous routing policy. YES consumes the request; schedule any tab mutations
// on the next main-loop turn. NO preserves Chromium navigation/popup semantics.
// request: url, disposition, userGesture, source (page/external), and optional
// sourceBundleID (OS Apple-event sender only, never inferred from the front app).
- (BOOL)engine:(AircEngine*)engine routeLink:(NSDictionary<NSString*, id>*)request
    opener:(nullable AircTab*)opener;
// Chromium monitor signal on the main thread: 0 none, 1 moderate, 2 critical.
- (void)engine:(AircEngine*)engine memoryPressure:(NSInteger)level;
@end

AIRC_EXPORT
@interface AircEngine : NSObject
+ (int)runWithArgc:(int)argc
              argv:(const char* _Nonnull* _Nonnull)argv
          delegate:(id<AircEngineDelegate>)delegate NS_SWIFT_NAME(run(argc:argv:delegate:));
@property(class, readonly, nullable) AircEngine* sharedEngine;
// Call from application:openURLs: while the Apple event is current. Returns NO
// when no policy handles it; the app must then apply its normal default route.
- (BOOL)routeExternalURL:(NSString*)url;
+ (nullable NSString*)currentEventSourceBundleID;

@property(readonly, nullable) AircProfile* defaultProfile;
- (void)loadProfile:(NSString*)directoryName
         completion:(void (^)(AircProfile* _Nullable profile))completion NS_SWIFT_NAME(loadProfile(directory:completion:));
- (void)quit;
@property(nonatomic, copy, nullable) NSString* pageScript;
+ (void)resolvePermission:(NSString*)requestId
                   result:(NSString*)result
                 remember:(BOOL)remember;
+ (void)resolveExtensionInstallPrompt:(NSString*)requestId accepted:(BOOL)accepted;
+ (void)startCasting:(int)dialogId sink:(NSString*)sinkId mode:(int)castMode;
+ (void)stopCasting:(int)dialogId route:(NSString*)routeId;
+ (void)closeCastDialog:(int)dialogId;
+ (void)terminateCastRoute:(NSString*)routeId;
+ (void)setAutoPictureInPicture:(BOOL)enabled;
+ (void)setVideoUpscaling:(BOOL)enabled;
+ (void)setVideoUpscalingTestConditions:(NSDictionary<NSString*, NSNumber*>*)conditions;
@property(class, readonly) NSDictionary<NSString*, id>* videoUpscalingState;
+ (void)reservedShortcutsChanged;
+ (void)selectDevice:(int)chooserId index:(int)index;
+ (void)cancelDeviceChooser:(int)chooserId;
+ (void)refreshDeviceChooser:(int)chooserId;
+ (void)openDeviceChooserSettings:(int)chooserId;
- (void)deleteProfile:(AircProfile*)profile
           completion:(nullable void (^)(BOOL deleted))completion;
// Does not load the profile. Refuses default/reserved and session-loaded folders.
// Completion follows filesystem removal; see PROFILE-SERVICES.md.
- (void)deleteUnloadedProfileDirectory:(NSString*)directoryName
                           completion:(void (^)(NSDictionary*))completion
    NS_SWIFT_NAME(deleteUnloadedProfile(directory:completion:));
- (void)releaseProfile:(AircProfile*)profile;
+ (void)resolveExternalApp:(NSString*)requestId open:(BOOL)open remember:(BOOL)remember;
@property(class, readonly) NSArray<NSDictionary*>* testExternalLaunches;
@property(class, readonly) NSArray<NSDictionary*>* testChooserEvents;
+ (void)allowDesktopCapture:(NSString*)sourceId
                        tab:(AircTab*)tab
                      frame:(nullable NSString*)frameId
                     origin:(nullable NSString*)origin
                      audio:(nullable NSString*)audio;
@property(class, readonly) NSDictionary<NSString*, NSNumber*>* desktopCaptureAudio;
- (void)offTheRecordProfileFor:(AircProfile*)profile
                    completion:(void (^)(AircProfile* _Nullable offTheRecord,
                                         NSString* _Nullable error))completion;
@property(readonly) NSString* chromiumVersion;
@property(readonly) NSString* keepAliveState;
@end

AIRC_EXPORT
@interface AircEngine (ProtectedContent)
// Main thread after engineDidStart. Global across profiles; persisted in Local State.
// Reload protected pages after a change; restart to end existing CDM/download work.
@property(nonatomic) BOOL protectedContentEnabled;
@property(readonly) NSDictionary<NSString*, id>* protectedContentState;
@end

@interface AircEngine (Tracing)
+ (void)beginTracing:(void (^)(BOOL started))completion;
+ (void)endTracing:(BOOL)keep completion:(void (^)(NSString* _Nullable path))completion;
@property(class, readonly) BOOL isTracing;
@end

AIRC_EXPORT
@interface AircProfile : NSObject
@property(readonly) NSString* name;
@property(readonly) NSString* path;
@property(readonly) BOOL offTheRecord;
@property(readonly) BOOL destroyed;
- (nullable NSString*)loadComponentExtension:(NSString*)path;
- (void)unloadComponentExtension:(NSString*)extensionId;
- (void)warmSpareRenderer;
- (void)holdNavigationsUntilRulesetsOf:(NSString*)extensionId;
- (void)releaseNavigationHold:(NSString*)reason;
- (void)releaseNavigationHoldReady;
- (void)watchCastRoutes;
@property BOOL passwordsOffered;
@property BOOL addressesAutofilled;
@property BOOL cardsAutofilled;
- (void)clearBrowsingData:(NSArray<NSString*>*)types
                    since:(nullable NSDate*)since
               completion:(nullable void (^)(void))completion;
@end

@interface AircProfile (ExtensionTesting)
// Unsigned mock-keychain scratch hosts only. Async fixture loader; no UI-thread disk I/O.
- (void)loadUnpackedExtensionForTesting:(NSString*)path
    completion:(void (^)(NSString* _Nullable extensionID, NSString* _Nullable error))completion;
@end

@interface AircEngine (MemoryTesting)
// Refused outside the existing unsigned, mock-keychain, scratch-profile test gate.
+ (BOOL)simulateMemoryPressureForTesting:(NSInteger)level;
@end

@interface AircProfile (PictureInPicture)
// Main thread. Persisted per profile; off wins over site allows.
@property BOOL autoPictureInPictureEnabled;
// nil clears the exception; returns NO for invalid/non-HTTP(S) origins.
- (BOOL)setAutoPictureInPictureException:(NSString*)origin enabled:(nullable NSNumber*)enabled;
// AppKit global screen points, bottom-left origin. NSZeroRect resets placement.
@property NSRect pictureInPictureFrame;
@end

// App-drawn picture-in-picture controls (engine/PIP.md "App overlay"). Main thread.
// The provider runs once per new PiP window, before its first frame, with info:
// kind (video/document), window (the PiP NSWindow), topBarHeight (document:
// Chromium's top bar in points). Return a view to host above the content, or nil
// for Chromium's own controls. The engine fills the content view with it. For
// video it hides Chromium's controls, title and scrims; the switch
// pipAppControls=off keeps them and never calls the provider. Its hitTest:
// decides each press: a subview gets the whole press directly (never activating
// Airc), the view itself is window-drag background, nil passes to Chromium.
@interface AircEngine (PictureInPictureOverlay)
+ (void)setPictureInPictureOverlayProvider:
    (nullable NSView* _Nullable (^)(AircTab* tab, NSDictionary<NSString*, id>* info))provider;
@end


@interface AircProfile (Memory)
// Seconds, per loaded profile; default 1800. Zero disables the inactivity deadline.
// Pressure handling still applies. The app persists the user's chosen setting.
@property NSTimeInterval unloadTimeout;
@end

@interface AircProfile (Icons)
- (void)fetchIcon:(NSString*)url
         maxBytes:(NSUInteger)maxBytes
       completion:(void (^)(NSData* _Nullable body))completion;
@end

@protocol AircWindowDelegate <NSObject>
@optional
- (void)window:(AircWindow*)window
    didInsertTab:(AircTab*)tab
          opener:(nullable AircTab*)opener
     disposition:(NSString*)disposition;
- (void)window:(AircWindow*)window didRemoveTab:(AircTab*)tab;
- (void)window:(AircWindow*)window didActivateTab:(AircTab*)tab;
- (void)window:(AircWindow*)window
    devToolsDidChangeForTab:(AircTab*)tab
                       view:(nullable NSView*)devToolsView;
- (void)window:(AircWindow*)window
                    tab:(AircTab*)tab
    didChangeFullscreen:(BOOL)fullscreen;
- (void)window:(AircWindow*)window
    passwordPrompt:(NSDictionary<NSString*, id>*)prompt
            forTab:(AircTab*)tab;
- (void)window:(AircWindow*)window
    autofillPrompt:(NSDictionary<NSString*, id>*)prompt
            forTab:(AircTab*)tab;
- (void)window:(AircWindow*)window
    passwordSavePromptForTab:(AircTab*)tab
                    username:(NSString*)username
                      origin:(NSString*)origin;
- (void)window:(AircWindow*)window showRequestedActive:(BOOL)active;
- (BOOL)windowShouldClose:(AircWindow*)window;
- (void)windowDidCancelClose:(AircWindow*)window;
- (void)window:(AircWindow*)window
    confirmCloseWithDownloads:(int)count
                   completion:(void (^)(BOOL closeAnyway))completion;
- (BOOL)window:(AircWindow*)window preHandleKeyEvent:(NSEvent*)event;
- (BOOL)window:(AircWindow*)window handleKeyEvent:(NSEvent*)event;
@end

AIRC_EXPORT
@interface AircWindow : NSObject
+ (nullable NSView*)embeddedRootOfWindow:(NSWindow*)window;
+ (Class)contentViewClass;
+ (BOOL)isChromeFramelessWindow:(NSWindow*)window;
- (instancetype)initWithContentRect:(NSRect)rect;
// The app retains the window and lays out hostView; its delegate is never replaced.
// Call close before releasing the window so beforeunload can complete.
- (instancetype)initWithWindow:(NSWindow*)window hostView:(NSView*)hostView;
@property(readonly) NSWindow* window;
@property(readonly) NSView* hostView;
@property(weak, nullable) id<AircWindowDelegate> delegate;

- (nullable AircTab*)openTab:(NSString*)url
              profile:(AircProfile*)profile
           foreground:(BOOL)foreground NS_SWIFT_NAME(openTab(url:profile:foreground:));
- (nullable AircTab*)openExtensionView:(NSString*)url
                                 profile:(AircProfile*)profile
                                    kind:(NSString*)kind;
@property(nonatomic, nullable) AircProfile* activeProfile;
- (void)activateTab:(AircTab*)tab;
// Detaches all pages and clears the active profile, keeping every tab alive.
- (void)deactivateAll;
- (NSArray<AircTab*>*)tabsForProfile:(AircProfile*)profile;
- (int)chromeWindowIdForProfile:(AircProfile*)profile;
- (BOOL)executeChromeCommand:(int)commandId profile:(AircProfile*)profile;
- (void)showInactive;
@property(nonatomic) BOOL actedFullScreen;
- (void)close;

- (void)prepareProfile:(AircProfile*)profile NS_SWIFT_NAME(prepareProfile(_:));
- (void)adoptTab:(AircTab*)tab;
- (nullable AircTab*)restoreTab:(nullable NSString*)state
                          profile:(AircProfile*)profile
                       foreground:(BOOL)foreground;
- (nullable AircTab*)duplicateTab:(AircTab*)source
                            profile:(AircProfile*)profile
                         foreground:(BOOL)foreground;
- (void)placeTab:(AircTab*)tab index:(int)index pinned:(BOOL)pinned;
@property(nonatomic) BOOL internal;
@end

@protocol AircTabDelegate <NSObject>
@optional
- (void)tabDidChangeTitle:(AircTab*)tab;
- (void)tabDidChangeURL:(AircTab*)tab;
- (void)tabDidChangeLoading:(AircTab*)tab;
- (void)tabDidChangeProgress:(AircTab*)tab;
- (void)tabDidChangeFavicon:(AircTab*)tab;
- (void)tabDidChangeNavigationState:(AircTab*)tab;
- (void)tab:(AircTab*)tab didFindMatches:(int)count active:(int)active final:(BOOL)final;
- (void)tab:(AircTab*)tab
    didReceivePageMessage:(NSString*)kind
                     json:(NSString*)json
                    frame:(NSString*)frameId
                     main:(BOOL)main
                   origin:(NSString*)origin;
- (void)tabWillClose:(AircTab*)tab;
// Host close completed its unload path. Defer tab-strip mutations from callbacks.
- (void)tabDidCloseForHost:(AircTab*)tab;
// The page rejected a host close (Stay); the tab remains open.
- (void)tabDidCancelClose:(AircTab*)tab;
// Opt in to host-owned password rows; no passwords are sent in these rows.
- (BOOL)tabWantsPasswordSuggestions:(AircTab*)tab;
- (void)tab:(AircTab*)tab rendererGone:(NSString*)status code:(int)code;
- (void)tab:(AircTab*)tab didFailLoad:(NSString*)url code:(int)code description:(NSString*)text;
- (void)tab:(AircTab*)tab didChangeStatusText:(NSString*)text;
- (void)tab:(AircTab*)tab didRequestAppURL:(NSString*)url userGesture:(BOOL)userGesture;
- (void)tabDidChangeThemeColor:(AircTab*)tab;
- (void)tabDidCommitDocument:(AircTab*)tab;
- (void)tabDidGainFocus:(AircTab*)tab;
- (void)tabDidChangeAudio:(AircTab*)tab;
- (void)tabDidChangeSecurity:(AircTab*)tab;
- (void)tabDidChangeZoom:(AircTab*)tab;
- (void)tab:(AircTab*)tab didBlockPopup:(NSDictionary<NSString*, NSString*>*)popup;
- (void)tab:(AircTab*)tab preferredSizeDidChange:(NSSize)size;
- (void)tab:(AircTab*)tab externalAppRequest:(NSDictionary<NSString*, id>*)request;
- (void)tab:(AircTab*)tab requestsActivation:(NSString*)reason;
- (void)tab:(AircTab*)tab didChangePictureInPicture:(NSDictionary<NSString*, id>*)state;
// Password rows carry "bounds": NSStringFromRect of the field in page-view DIPs (top-left origin).
- (void)tab:(AircTab*)tab didShowAutofillSuggestions:(NSArray<NSDictionary<NSString*, NSString*>*>*)items;
- (void)tab:(AircTab*)tab didBlockRequests:(int)count lastURL:(NSString*)url;
- (NSArray<NSDictionary<NSString*, NSString*>*>*)tab:(AircTab*)tab
                         contextMenuItemsForSelection:(NSString*)text;
- (void)tab:(AircTab*)tab
    contextMenuCommand:(NSString*)itemId
                  text:(NSString*)selection
             modifiers:(NSDictionary<NSString*, NSNumber*>*)modifiers;
- (void)tab:(AircTab*)tab shareFromContextMenu:(NSDictionary<NSString*, id>*)share;
- (void)tab:(AircTab*)tab didShowContextMenu:(NSArray<NSDictionary*>*)items;
- (nullable NSDictionary<NSString*, id>*)tab:(AircTab*)tab
                              runContextMenu:(NSDictionary<NSString*, id>*)menu;
// SP-31: return [{id, title}] Space identifiers, not profile identifiers.
- (NSArray<NSDictionary*>*)tab:(AircTab*)tab spacesForContextMenuLink:(NSString*)url;
- (void)tab:(AircTab*)tab openContextMenuLink:(NSString*)url inSpace:(NSString*)spaceID;
- (void)tab:(AircTab*)tab navigationBecameDownload:(NSString*)url;
- (void)tabDidChangeDiscarded:(AircTab*)tab;
// Renderer acknowledgement, including keys in child frames. No synthetic JS events.
- (void)tab:(AircTab*)tab didReceiveShortcut:(NSString*)combo pageUsedIt:(BOOL)used;
- (void)tabBecameUnresponsive:(AircTab*)tab;
- (void)tabBecameResponsive:(AircTab*)tab;
- (void)tab:(AircTab*)tab didChangeMediaAccess:(NSDictionary<NSString*, NSNumber*>*)access;
@end

AIRC_EXPORT
@interface AircTab : NSObject
@property(readonly) NSView* view;
@property(readonly, weak) AircProfile* profile;
@property(readonly) int tabId;
@property(readonly) NSString* url;
@property(readonly) NSString* title;
@property(readonly) BOOL loading;
@property(readonly) double progress;
@property(readonly, nullable) NSImage* favicon;
@property(readonly) BOOL canGoBack;
@property(readonly) BOOL canGoForward;
@property(readonly) BOOL closed;
@property(weak, nullable) id<AircTabDelegate> delegate;

- (void)focus;
- (void)find:(NSString*)text forward:(BOOL)forward;
- (void)stopFinding;
// Snapshot: text, matches, active (1-based; 0 means none), final. Updates arrive
// through tab:didFindMatches:active:final:. Visibility/focus belongs to the app.
@property(readonly) NSDictionary<NSString*, id>* findState;
- (void)close;
@property(readonly, nullable) NSDictionary<NSString*, id>* passwordPrompt;
- (void)resolvePasswordPrompt:(NSString*)action
                     username:(nullable NSString*)username
                     password:(nullable NSString*)password;
@property(readonly, nullable) NSDictionary<NSString*, id>* autofillPrompt;
- (void)resolveAutofillPrompt:(NSInteger)promptId action:(NSString*)action;
// Use the opaque integer "index" from the latest didShowAutofillSuggestions rows.
// Invalidated on hide, focus change, navigation, or replacement; stale indices fail.
- (BOOL)acceptAutofillSuggestion:(NSInteger)index;
- (void)hideAutofillSuggestions;

@property(readonly, nullable) NSString* faviconURL;
@property(readonly, nullable) NSString* themeColor;
@property(readonly) BOOL audible;
@property(nonatomic) BOOL muted;
@property(readonly) int browserId;
@property(readonly, nullable) NSString* committedOrigin;
+ (nullable NSString*)originForURL:(NSString*)url;
@property(readonly) BOOL initialDocumentAccessed;
@property(readonly) BOOL committedInitial;
- (nullable id)suppressInput;
- (void)closeNow;
@property(nonatomic) BOOL temporary;
- (void)setTemporarySource:(nullable AircTab*)source;
- (void)deliverHeldPageMessages;
@property(readonly) NSDictionary<NSString*, id>* securityInfo;
// Refuses visible, audible, captured, loading or edited pages. Preserves navigation state.
- (BOOL)discard;
@property(readonly) BOOL discarded;
@property(nonatomic) BOOL frozen;
- (void)resolveUnresponsive:(BOOL)terminate;
- (BOOL)showAutofillSuggestions:(BOOL)passwords;
@property(readonly, nullable) NSDictionary<NSString*, NSNumber*>* popupFeatures;
@property(readonly) NSSize preferredSize;
@end

@interface AircTab (PictureInPicture)
// Selected page's host window gained/lost key status. Does not hide its view.
- (void)setPictureInPictureWindowActive:(BOOL)active;
// This tab's open PiP, or nil: kind, window, appOverlay (the hosted view or
// NSNull), chromeControls (Chromium's video controls container drawn).
@property(readonly, nullable) NSDictionary<NSString*, id>* pictureInPictureState;
@end


@interface AircTab (Navigation)
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;
- (void)loadURL:(NSString*)url userInitiated:(BOOL)userInitiated;
- (void)goToOffset:(int)offset;
- (void)reloadIgnoringCache;
- (void)loadIfNeeded;
@property(readonly) NSArray<NSDictionary<NSString*, id>*>* navigationEntries;
@end

@interface AircTab (Page)
- (void)executeJavaScript:(NSString*)code frame:(nullable NSString*)frameId;
- (void)evaluate:(NSString*)code completion:(void (^)(NSString* _Nullable json))completion;
- (BOOL)hasLiveFrame:(NSString*)frameId;
- (void)callPage:(NSString*)kind json:(NSString*)json;
- (void)callFrame:(NSString*)frameId kind:(NSString*)kind json:(NSString*)json;
- (void)grantUserActivationToFrame:(NSString*)frameId;
@property(nonatomic, nullable) NSColor* pageBackgroundColor;
@property(nonatomic, copy, nullable) NSString* pageColor;
@property(nonatomic, nullable) NSColor* contentsBackgroundColor;
@property(nonatomic) double zoomFactor;
- (void)zoomStep:(int)direction;
@property(readonly) double pinchScale;
@end

@interface AircTab (Commands)
- (BOOL)executeChromeCommand:(int)command;
- (void)openBlockedPopup:(NSString*)popupId always:(BOOL)always;
- (void)showDevTools;
- (void)closeDevTools;
@property(readonly, nullable) NSView* devToolsView;
- (void)attachDevToolsToView:(NSView*)host NS_SWIFT_NAME(attachDevTools(to:));
- (void)copyDevToolsPicture:(NSTimeInterval)timeout
                completion:(void (^)(CGImageRef _Nullable image))completion;
- (void)devToolsLayoutForSize:(NSSize)size
                     devTools:(NSRect*)devToolsFrame
                         page:(NSRect*)pageFrame;
// Read-only native modal diagnostics, available only with --airc-test=modalDialogs
// under the unsigned scratch/mock-keychain test gate. Empty outside that gate.
- (NSDictionary*)modalDialogStateForTesting;
// Invoke the same Cancel handler as the dialog button when an off-Space window
// cannot receive native key events. Same test gate as the read-only diagnostics.
- (BOOL)cancelModalDialogForTesting;
// Same scratch-only gate; invokes the native dialog's Accept or Cancel handler.
- (BOOL)respondToModalDialogForTesting:(BOOL)accept;
// Select only the phone/QR mechanism of a synthetic request, using its real
// button callback. Same test gate; never selects a saved credential.
- (BOOL)selectHybridMechanismForTesting;

- (void)devToolsCall:(NSString*)method
              params:(nullable NSDictionary*)params
             timeout:(NSTimeInterval)timeout
          completion:(void (^)(NSDictionary* _Nullable result,
                               NSString* _Nullable error))completion;
@end

@interface AircTab (Media)
@property(readonly, nullable) NSString* mediaCaptureSourceId;
- (void)copyPicture:(NSTimeInterval)timeout completion:(void (^)(CGImageRef _Nullable picture))completion;
- (BOOL)stopCapture;
- (void)noteShownByHost:(BOOL)shown;
- (void)exitFullscreen;
- (void)exitExclusiveAccess;
- (void)tracePictureInPicture:(NSString*)line withInputs:(BOOL)withInputs;
- (void)exitPictureInPicture;
// Explicit native host action (e.g. closing Little Arc). Retain the tab and its
// owner until PiP ends; closing the WebContents destroys its player. Completion
// reports element entry, or session/NO when the site's asynchronous handler owns it.
- (void)enterPictureInPictureForHost:(void (^)(NSString* route, BOOL opened))completion;
- (void)enterPictureInPictureForClickAt:(NSTimeInterval)clickTime
                             completion:(void (^)(NSString* route, BOOL opened))completion;
- (BOOL)canShareThisTabInsteadFor:(AircTab*)capturer;
- (BOOL)shareThisTabInsteadFor:(AircTab*)capturer;
- (BOOL)showCastDialog;
- (BOOL)devShowBluetoothChooser:(BOOL)unauthorized;
@end

@interface AircTab (Extensions)
- (NSString*)executeExtensionAction:(NSString*)extensionId;
- (NSDictionary<NSString*, NSDictionary*>*)actionStatesForExtensions:(NSArray<NSString*>*)extensionIds;
- (nullable NSString*)sidePanelURLForExtension:(NSString*)extensionId;
@end

typedef NS_ENUM(NSInteger, AircPageScrollAck) {
  AircPageScrollAckBegin,
  AircPageScrollAckUpdate,
};

@protocol AircPageScrollObserver <NSObject>
- (void)pageView:(NSView*)view
     ackedScroll:(AircPageScrollAck)ack
        consumed:(BOOL)consumed;
- (void)pageView:(NSView*)view overscrolledAllowingHorizontal:(BOOL)allowed;
@end

AIRC_EXPORT
@interface AircPageView : NSObject
+ (BOOL)isPageView:(NSView*)view;
+ (void)setScrollObserver:(nullable id<AircPageScrollObserver>)observer;
+ (BOOL)takeSwipes:(NSView*)view;
+ (BOOL)takesSwipes:(NSView*)view;
+ (BOOL)isEditingText:(NSView*)view;
@end

// All host API calls are on the main thread after engineDidStart.
// A hidden profile must only be used in an AircWindow with internal = YES.
@interface AircEngine (HostAPI)
@property(readonly) NSArray<NSString*>* profileDirectoryNames;
- (void)createProfileWithCompletion:(void (^)(AircProfile* _Nullable))completion
    NS_SWIFT_NAME(createProfile(completion:));
- (void)loadInternalProfileWithCompletion:(void (^)(AircProfile* _Nullable))completion
    NS_SWIFT_NAME(loadInternalProfile(completion:));
@end
@interface AircProfile (HostAPI)
@property(readonly) NSArray<NSDictionary<NSString*, id>*>* extensions;
@end
// Services are bound to this profile. Completion/visit blocks run on the UI thread.
@interface AircProfile (Services)
- (void)queryHistory:(NSString*)query limit:(NSInteger)limit
         completion:(void (^)(NSArray<NSDictionary*>*))completion;
// Pass nil to stop. Do not strongly capture the profile in this block.
- (void)observeHistoryVisits:(nullable void (^)(NSDictionary*))handler;
// Progress snapshots include id/url/path/received/total/state/paused/dangerous.
- (void)observeDownloads:(nullable void (^)(NSDictionary*))handler;
// Cached IdentityManager cookie accounts. fresh=false is NOT signed out.
@property(readonly) NSDictionary* googleAccounts;
// Plaintext input stays in memory; Chromium owns encryption and database writes.
// See PROFILE-SERVICES.md for keys, limits, and acknowledgement semantics.
- (void)importLogins:(NSArray<NSDictionary*>*)logins completion:(void (^)(NSDictionary*))completion;
- (void)importCookies:(NSArray<NSDictionary*>*)cookies completion:(void (^)(NSDictionary*))completion;
@end
@interface AircTab (Hosting)
// Multiple attached tabs remain visible independently of selected profile/tab.
@property(readonly) BOOL pageVisible;
// Isolated per-tab zoom; use for panes, including same-origin panes.
@property BOOL independentZoom;
// Activate through AircWindow first, then attach. Focus is explicit.
- (void)attachToView:(NSView*)host NS_SWIFT_NAME(attach(to:));
- (void)detachFromHost NS_SWIFT_NAME(detach());
// Keeps the NSView in its parent; propagates visibility to Chromium and prompts.
- (void)setPageVisible:(BOOL)visible;
@end

// App-owned permission/password/chooser panels use this anchor in delegate callbacks.
// It does not redirect every upstream Views bubble; see the parity limitations.
@interface AircWindow (Hosting)
// Main thread, synchronous. nil means success; otherwise no mutation:
// profileMismatch, closedTab, invalidHost, busy, closingWindow, missingOwner.
// Same-profile Spaces are app metadata. Never use this to change profiles.
- (nullable NSString*)moveTab:(AircTab*)tab profile:(AircProfile*)profile
    toView:(NSView*)view NS_SWIFT_NAME(moveTab(_:profile:to:));
// Opens an ordinary live tab in the opener profile and attaches above the page.
// Promotion uses moveTab; dismissal uses tab.close (beforeunload still applies).
- (nullable AircTab*)openPeek:(NSString*)url opener:(AircTab*)opener
    inView:(NSView*)view NS_SWIFT_NAME(openPeek(url:opener:in:));
@property(nonatomic, weak, nullable) NSView* uiAnchorView;
// In uiAnchorView coordinates. Default is its bounds; resetting uiAnchorView resets rect.
@property(nonatomic) NSRect uiAnchorRect;
@property(readonly) NSRect uiAnchorRectInScreen;
- (nullable AircTab*)openExtensionsPageForProfile:(AircProfile*)profile;
- (nullable AircTab*)openWebStoreForProfile:(AircProfile*)profile;
// Rect in the supplied view's coordinates. A nonactivating, profile-bound panel.
// Dismiss on Escape/outside clicks; activation/profile changes also dismiss it.
- (nullable AircTab*)presentActionPopupForExtension:(NSString*)extensionID tab:(AircTab*)tab
    anchorRect:(NSRect)rect inView:(NSView*)view;
- (void)closeActionPopup;
// Performs the toolbar action (including activeTab grant). Attach the returned popup
// tab's view to an app-owned panel, and close it when the panel is dismissed.
- (nullable AircTab*)openActionPopupForExtension:(NSString*)extensionID tab:(AircTab*)tab
    NS_SWIFT_NAME(openActionPopup(extensionID:tab:));
@end
// Pass 13: dictionary keys, actions and lifetimes are specified in PASS13.md.
@interface AircProfile (Library)
@property(readonly) NSArray<NSDictionary*>* downloads;
- (BOOL)performDownloadAction:(NSString*)action identifier:(NSString*)identifier;
- (nullable NSString*)downloadPath:(NSString*)identifier;
@property(readonly) NSArray<AircTab*>* mediaTabs;
- (void)observeMediaTabs:(nullable void (^)(NSArray<AircTab*>*))handler;
@end
@interface AircTab (MediaSession)
@property(readonly) NSDictionary* mediaSession;
- (void)observeMediaSession:(nullable void (^)(NSDictionary*))handler;
- (BOOL)performMediaAction:(NSString*)action value:(double)value;
@end
@interface AircProfile (SiteControls)
- (NSDictionary*)sitePermissions:(NSString*)origin;
- (BOOL)setSitePermission:(NSString*)permission state:(NSString*)state origin:(NSString*)origin;
- (BOOL)resetSitePermissions:(NSString*)origin;
- (void)observeSitePermissions:(nullable void (^)(NSString* origin))handler;
- (void)siteData:(NSString*)origin completion:(void (^)(NSDictionary*))completion;
- (void)clearSiteData:(NSString*)origin completion:(void (^)(BOOL))completion;
@property(readonly) double defaultSiteZoomFactor;
- (double)siteZoomFactor:(NSString*)origin;
- (BOOL)setSiteZoomFactor:(double)factor origin:(NSString*)origin;
- (BOOL)resetSiteZoom:(NSString*)origin;
@end
NS_ASSUME_NONNULL_END

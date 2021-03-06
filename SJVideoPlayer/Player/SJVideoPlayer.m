//
//  SJVideoPlayer.m
//  SJVideoPlayerProject
//
//  Created by BlueDancer on 2017/11/29.
//  Copyright © 2017年 SanJiang. All rights reserved.
//

#import "SJVideoPlayer.h"
#import <SJVideoPlayerAssetCarrier/SJVideoPlayerAssetCarrier.h>
#import <Masonry/Masonry.h>
#import "SJVideoPlayerPresentView.h"
#import "SJVideoPlayerControlView.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import "SJVideoPlayerMoreSettingsView.h"
#import "SJVideoPlayerMoreSettingSecondaryView.h"
#import <SJOrentationObserver/SJOrentationObserver.h>
#import "SJVideoPlayerRegistrar.h"
#import <SJVolBrigControl/SJVolBrigControl.h>
#import "SJTimerControl.h"
#import "SJVideoPlayerView.h"
#import <SJLoadingView/SJLoadingView.h>
#import "SJPlayerGestureControl.h"
#import <SJUIFactory/SJUIFactory.h>
#import "SJVideoPlayerDraggingProgressView.h"
#import <SJAttributesFactory/SJAttributeWorker.h>

#define MoreSettingWidth (MAX([UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height) * 0.382)

inline static void _sjErrorLog(id msg) {
    NSLog(@"__error__: %@", msg);
}

inline static void _sjHiddenViews(NSArray<UIView *> *views) {
    [views enumerateObjectsUsingBlock:^(UIView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        obj.alpha = 0.001;
    }];
}

inline static void _sjShowViews(NSArray<UIView *> *views) {
    [views enumerateObjectsUsingBlock:^(UIView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        obj.alpha = 1;
    }];
}

inline static void _sjAnima(void(^block)(void)) {
    if ( block ) {
        [UIView animateWithDuration:0.3 animations:^{
            block();
        }];
    }
}

inline static void _sjAnima_Complete(void(^block)(void), void(^complete)(void)) {
    if ( block ) {
        [UIView animateWithDuration:0.3 animations:^{
            block();
        } completion:^(BOOL finished) {
            if ( complete ) complete();
        }];
    }
}

#pragma mark -

@interface SJVideoPlayer ()<SJVideoPlayerControlViewDelegate, SJSliderDelegate>

@property (class, nonatomic, strong, readonly) dispatch_queue_t workQueue;

@property (nonatomic, strong, readonly) SJVideoPlayerPresentView *presentView;
@property (nonatomic, strong, readonly) SJVideoPlayerControlView *controlView;
@property (nonatomic, strong, readonly) SJVideoPlayerMoreSettingsView *moreSettingView;
@property (nonatomic, strong, readonly) SJVideoPlayerMoreSettingSecondaryView *moreSecondarySettingView;
@property (nonatomic, strong, readonly) SJOrentationObserver *orentation;
@property (nonatomic, strong, readonly) SJMoreSettingsFooterViewModel *moreSettingFooterViewModel;
@property (nonatomic, strong, readonly) SJVideoPlayerRegistrar *registrar;
@property (nonatomic, strong, readonly) SJVolBrigControl *volBrigControl;
@property (nonatomic, strong, readonly) SJPlayerGestureControl *gestureControl;
@property (nonatomic, strong, readonly) SJLoadingView *loadingView;
@property (nonatomic, strong, readonly) SJVideoPlayerDraggingProgressView *draggingProgressView;

@property (nonatomic, strong, readwrite) SJVideoPlayerAssetCarrier *asset;
@property (nonatomic, assign, readwrite) SJVideoPlayerPlayState state;
@property (nonatomic, assign, readwrite) BOOL hiddenMoreSettingView;
@property (nonatomic, assign, readwrite) BOOL hiddenMoreSecondarySettingView;
@property (nonatomic, assign, readwrite) BOOL hiddenLeftControlView;
@property (nonatomic, assign, readwrite) BOOL userClickedPause;
@property (nonatomic, assign, readwrite) BOOL suspend; // Set it when the [`pause` + `play` + `stop`] is called.
@property (nonatomic, assign, readonly)  BOOL playOnCell;
@property (nonatomic, assign, readwrite) BOOL scrollIn;
@property (nonatomic, assign, readwrite) BOOL touchedScrollView;
@property (nonatomic, assign, readwrite) BOOL stopped; // Set it when the [`play` + `stop`] is called.
@property (nonatomic, strong, readwrite) NSError *error;

- (void)_play;
- (void)_pause;

@end





#pragma mark - State

@interface SJVideoPlayer (State)

@property (nonatomic, assign, readwrite, getter=isHiddenControl) BOOL hideControl;
@property (nonatomic, assign, readwrite, getter=isLockedScrren) BOOL lockScreen;

- (void)_cancelDelayHiddenControl;

- (void)_delayHiddenControl;

- (void)_prepareState;

- (void)_playState;

- (void)_pauseState;

- (void)_playEndState;

- (void)_playFailedState;

- (void)_unknownState;

@end

@implementation SJVideoPlayer (State)

- (SJTimerControl *)timerControl {
    SJTimerControl *timerControl = objc_getAssociatedObject(self, _cmd);
    if ( timerControl ) return timerControl;
    timerControl = [SJTimerControl new];
    objc_setAssociatedObject(self, _cmd, timerControl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return timerControl;
}

- (void)_cancelDelayHiddenControl {
    [self.timerControl reset];
}

- (void)_delayHiddenControl {
    __weak typeof(self) _self = self;
    [self.timerControl start:^(SJTimerControl * _Nonnull control) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( self.state == SJVideoPlayerPlayState_Pause ) return;
        _sjAnima(^{
            self.hideControl = YES;
        });
    }];
}

- (void)setLockScreen:(BOOL)lockScreen {
    if ( self.isLockedScrren == lockScreen ) return;
    objc_setAssociatedObject(self, @selector(isLockedScrren), @(lockScreen), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self _cancelDelayHiddenControl];
    _sjAnima(^{
        if ( lockScreen ) {
            [self _lockScreenState];
        }
        else {
            [self _unlockScreenState];
        }
    });
}

- (BOOL)isLockedScrren {
    return [objc_getAssociatedObject(self, _cmd) boolValue];
}

- (void)setHideControl:(BOOL)hideControl {
    [self.timerControl reset];
    if ( hideControl ) [self _hideControlState];
    else {
        [self _showControlState];
        [self _delayHiddenControl];
    }

    BOOL oldValue = self.isHiddenControl;
    if ( oldValue != hideControl ) {
        objc_setAssociatedObject(self, @selector(isHiddenControl), @(hideControl), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ( self.controlViewDisplayStatus ) self.controlViewDisplayStatus(self, !hideControl);
    }
}

- (BOOL)isHiddenControl {
    return [objc_getAssociatedObject(self, _cmd) boolValue];
}

- (void)_unknownState {
    // hidden
    _sjHiddenViews(@[self.controlView, self.draggingProgressView]);
    
    self.state = SJVideoPlayerPlayState_Unknown;
}

- (void)_prepareState {
    // show
    _sjShowViews(@[self.controlView]);
    
    // hidden
    self.controlView.previewView.hidden = YES;
    _sjHiddenViews(@[
                     self.draggingProgressView,
                     self.controlView.topControlView.previewBtn,
                     self.controlView.leftControlView.lockBtn,
                     self.controlView.centerControlView.failedBtn,
                     self.controlView.centerControlView.replayBtn,
                     self.controlView.bottomControlView.playBtn,
                     self.controlView.bottomProgressSlider,
                     ]);
    
    if ( self.orentation.fullScreen ) {
        _sjShowViews(@[self.controlView.topControlView.moreBtn,]);
        self.hiddenLeftControlView = NO;
        if ( self.asset.hasBeenGeneratedPreviewImages ) {
            _sjShowViews(@[self.controlView.topControlView.previewBtn]);
        }
    }
    else {
        self.hiddenLeftControlView = YES;
        _sjHiddenViews(@[self.controlView.topControlView.moreBtn,
                         self.controlView.topControlView.previewBtn,]);
    }
    
    self.state = SJVideoPlayerPlayState_Prepare;
}

- (void)_playState {
    
    // show
    _sjShowViews(@[self.controlView.bottomControlView.pauseBtn]);
    
    // hidden
    _sjHiddenViews(@[
                     self.draggingProgressView,
                     self.controlView.bottomControlView.playBtn,
                     self.controlView.centerControlView.replayBtn,
                     ]);
    
    self.state = SJVideoPlayerPlayState_Playing;
}

- (void)_pauseState {
    
    // show
    _sjShowViews(@[self.controlView.bottomControlView.playBtn]);
    
    // hidden
    _sjHiddenViews(@[self.controlView.bottomControlView.pauseBtn]);
    
    self.state = SJVideoPlayerPlayState_Pause;
}

- (void)_playEndState {
    
    // show
    _sjShowViews(@[self.controlView.centerControlView.replayBtn,
                   self.controlView.bottomControlView.playBtn]);
    
    // hidden
    _sjHiddenViews(@[self.controlView.bottomControlView.pauseBtn]);
    
    
    self.state = SJVideoPlayerPlayState_PlayEnd;
}

- (void)_playFailedState {
    // show
    _sjShowViews(@[self.controlView.centerControlView.failedBtn]);
    
    // hidden
    _sjHiddenViews(@[self.controlView.centerControlView.replayBtn]);
    
    self.state = SJVideoPlayerPlayState_PlayFailed;
}

- (void)_lockScreenState {
    
    // show
    _sjShowViews(@[self.controlView.leftControlView.lockBtn]);
    
    // hidden
    _sjHiddenViews(@[self.controlView.leftControlView.unlockBtn]);
    self.hideControl = YES;
}

- (void)_unlockScreenState {
    
    // show
    _sjShowViews(@[self.controlView.leftControlView.unlockBtn]);
    self.hideControl = NO;
    
    // hidden
    _sjHiddenViews(@[self.controlView.leftControlView.lockBtn]);
    
}

- (void)_hideControlState {
    
    // show
    _sjShowViews(@[self.controlView.bottomProgressSlider]);
    
    // hidden
    self.controlView.previewView.hidden = YES;
    
    // transform hidden
    self.controlView.topControlView.transform = CGAffineTransformMakeTranslation(0, -self.controlView.topViewHeight);
    self.controlView.bottomControlView.transform = CGAffineTransformMakeTranslation(0, self.controlView.bottomViewHeight);
    
    if ( self.orentation.fullScreen ) {
        if ( self.isLockedScrren ) self.hiddenLeftControlView = NO;
        else self.hiddenLeftControlView = YES;
    }

    if ( self.orentation.fullScreen ) {
        [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade];
    }
    else {
        [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationFade];
    }
}

- (void)_showControlState {
    
    // hidden
    _sjHiddenViews(@[self.controlView.bottomProgressSlider]);
    self.controlView.previewView.hidden = YES;
    
    if ( !self.orentation.isFullScreen ) {
        _sjHiddenViews(@[self.controlView.topControlView.previewBtn, self.controlView.topControlView.moreBtn]);
        self.controlView.topControlView.titleLabel.hidden = YES;
    }
    else  {
        if ( self.generatePreviewImages &&
             self.asset.generatedPreviewImages ) {
            _sjShowViews(@[self.controlView.topControlView.previewBtn]);
        }

        _sjShowViews(@[self.controlView.topControlView.moreBtn]);
        self.controlView.topControlView.titleLabel.hidden = NO;
    }
    
    // transform show
    if ( self.playOnCell && !self.orentation.fullScreen ) {
        self.controlView.topControlView.transform = CGAffineTransformMakeTranslation(0, -self.controlView.topViewHeight);
    }
    else {
        self.controlView.topControlView.transform = CGAffineTransformIdentity;
    }
    self.controlView.bottomControlView.transform = CGAffineTransformIdentity;
    
    self.hiddenLeftControlView = !self.orentation.fullScreen;
    
    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationFade];
}

@end


#pragma mark - SJVideoPlayer
#import "SJMoreSettingsFooterViewModel.h"

@implementation SJVideoPlayer {
    SJVideoPlayerPresentView *_presentView;
    SJVideoPlayerControlView *_controlView;
    SJVideoPlayerMoreSettingsView *_moreSettingView;
    SJVideoPlayerMoreSettingSecondaryView *_moreSecondarySettingView;
    SJOrentationObserver *_orentation;
    SJVideoPlayerView *_view;
    SJMoreSettingsFooterViewModel *_moreSettingFooterViewModel;
    SJVideoPlayerRegistrar *_registrar;
    SJVolBrigControl *_volBrigControl;
    SJLoadingView *_loadingView;
    SJPlayerGestureControl *_gestureControl;
    SJVideoPlayerAssetCarrier *_asset;
    dispatch_queue_t _workQueue;
    SJVideoPlayerDraggingProgressView *_draggingProgressView;
}

+ (instancetype)sharedPlayer {
    static id _instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}

+ (instancetype)player {
    return [[self alloc] init];
}

#pragma mark

- (instancetype)init {
    self = [super init];
    if ( !self )  return nil;
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setCategory: AVAudioSessionCategoryPlayback error:&error];
    if ( error ) {
        _sjErrorLog([NSString stringWithFormat:@"%@", error.userInfo]);
    }
    
    [self view];
    [self volBrig];
    [self registrar];
    
    // default values
    self.autoplay = YES;
    self.generatePreviewImages = YES;
    
    [self _unknownState];
    
    SJVideoPlayer.update(^(SJVideoPlayerSettings * _Nonnull commonSettings) {});
    return self;
}

- (void)dealloc {
    self.state = SJVideoPlayerPlayState_Unknown;
    [self stop];
    NSLog(@"%s - %zd", __func__, __LINE__);
}

- (BOOL)playOnCell {
    return self.asset.indexPath ? YES : NO;
}

#pragma mark -
static dispatch_queue_t videoPlayerWorkQueue;
+ (dispatch_queue_t)workQueue {
    if ( videoPlayerWorkQueue ) return videoPlayerWorkQueue;
    videoPlayerWorkQueue = dispatch_queue_create("com.SJVideoPlayer.workQueue", DISPATCH_QUEUE_SERIAL);
    return videoPlayerWorkQueue;
}

+ (void)_addOperation:(void(^)(void))block {
    dispatch_async([self workQueue], ^{
        if ( block ) block();
    });
}

#pragma mark -

- (UIView *)view {
    if ( _view ) return _view;
    _view = [SJVideoPlayerView new];
    _view.backgroundColor = [UIColor blackColor];
    [_view addSubview:self.presentView];
    [_presentView addSubview:self.controlView];
    [_presentView addSubview:self.moreSettingView];
    [_presentView addSubview:self.moreSecondarySettingView];
    [_presentView addSubview:self.draggingProgressView];
    [self gesturesHandleWithTargetView:_controlView];
    self.hiddenMoreSettingView = YES;
    self.hiddenMoreSecondarySettingView = YES;
    _controlView.delegate = self;
    _controlView.bottomControlView.progressSlider.delegate = self;
    
    [_presentView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(_presentView.superview);
    }];
    
    [_controlView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(_controlView.superview);
    }];
    
    [_draggingProgressView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.center.offset(0);
    }];
    
    [_moreSettingView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.bottom.trailing.offset(0);
        make.width.offset(MoreSettingWidth);
    }];
    
    [_moreSecondarySettingView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(_moreSettingView);
    }];
    
    _loadingView = [SJLoadingView new];
    [_controlView addSubview:_loadingView];
    [_loadingView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.center.offset(0);
    }];
    
    __weak typeof(self) _self = self;
    _view.setting = ^(SJVideoPlayerSettings * _Nonnull setting) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        self.loadingView.lineColor = setting.loadingLineColor;
    };
    
    return _view;
}

- (SJVideoPlayerPresentView *)presentView {
    if ( _presentView ) return _presentView;
    _presentView = [SJVideoPlayerPresentView new];
    _presentView.clipsToBounds = YES;
    __weak typeof(self) _self = self;
    _presentView.readyForDisplay = ^(SJVideoPlayerPresentView * _Nonnull view, CGRect videoRect) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        if ( self.asset.hasBeenGeneratedPreviewImages ) { return ; }
        if ( !self.generatePreviewImages ) return;
        CGRect bounds = videoRect;
        CGFloat width = SJScreen_W() * 0.6;
        CGFloat height = width * bounds.size.height / bounds.size.width;
        CGSize size = CGSizeMake(width, height);
        [self.asset generatedPreviewImagesWithMaxItemSize:size completion:^(SJVideoPlayerAssetCarrier * _Nonnull asset, NSArray<SJVideoPreviewModel *> * _Nullable images, NSError * _Nullable error) {
            __strong typeof(_self) self = _self;
            if ( !self ) return;
            if ( error ) {
                _sjErrorLog(@"Generate Preview Image Failed!");
            }
            else {
                if ( self.orentation.fullScreen ) {
                    _sjAnima(^{
                        _sjShowViews(@[self.controlView.topControlView.previewBtn]);
                    });
                }
                self.controlView.previewView.previewImages = images;
            }
        }];
    };
    return _presentView;
}

- (SJVideoPlayerControlView *)controlView {
    if ( _controlView ) return _controlView;
    _controlView = [[SJVideoPlayerControlView alloc] initWithOrentationObserver:self.orentation];
    _controlView.clipsToBounds = YES;
    return _controlView;
}

- (SJVideoPlayerMoreSettingsView *)moreSettingView {
    if ( _moreSettingView ) return _moreSettingView;
    _moreSettingView = [[SJVideoPlayerMoreSettingsView alloc] initWithOrentationObserver:self.orentation];
    return _moreSettingView;
}

- (SJVideoPlayerMoreSettingSecondaryView *)moreSecondarySettingView {
    if ( _moreSecondarySettingView ) return _moreSecondarySettingView;
    _moreSecondarySettingView = [SJVideoPlayerMoreSettingSecondaryView new];
    _moreSettingFooterViewModel = [SJMoreSettingsFooterViewModel new];
    __weak typeof(self) _self = self;
    _moreSettingFooterViewModel.needChangeBrightness = ^(float brightness) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        self.volBrigControl.brightness = brightness;
    };
    
    _moreSettingFooterViewModel.needChangePlayerRate = ^(float rate) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( !self.asset ) return;
        self.rate = rate;
        [self showTitle:[NSString stringWithFormat:@"%.0f %%", self.rate * 100]];
        if ( self.internallyChangedRate ) self.internallyChangedRate(self, rate);
    };
    
    _moreSettingFooterViewModel.needChangeVolume = ^(float volume) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        self.volBrigControl.volume = volume;
    };
    
    _moreSettingFooterViewModel.initialVolumeValue = ^float{
        __strong typeof(_self) self = _self;
        if ( !self ) return 0;
        return self.volBrigControl.volume;
    };
    
    _moreSettingFooterViewModel.initialBrightnessValue = ^float{
        __strong typeof(_self) self = _self;
        if ( !self ) return 0;
        return self.volBrigControl.brightness;
    };
    
    _moreSettingFooterViewModel.initialPlayerRateValue = ^float{
        __strong typeof(_self) self = _self;
        if ( !self ) return 0;
        return self.rate;
    };
    
    _moreSettingView.footerViewModel = _moreSettingFooterViewModel;
    return _moreSecondarySettingView;
}

#pragma mark -

- (void)setHiddenMoreSettingView:(BOOL)hiddenMoreSettingView {
    if ( hiddenMoreSettingView == _hiddenMoreSettingView ) return;
    _hiddenMoreSettingView = hiddenMoreSettingView;
    if ( hiddenMoreSettingView ) {
        _moreSettingView.transform = CGAffineTransformMakeTranslation(MoreSettingWidth, 0);
    }
    else {
        _moreSettingView.transform = CGAffineTransformIdentity;
    }
}

- (void)setHiddenMoreSecondarySettingView:(BOOL)hiddenMoreSecondarySettingView {
    if ( hiddenMoreSecondarySettingView == _hiddenMoreSecondarySettingView ) return;
    _hiddenMoreSecondarySettingView = hiddenMoreSecondarySettingView;
    if ( hiddenMoreSecondarySettingView ) {
        _moreSecondarySettingView.transform = CGAffineTransformMakeTranslation(MoreSettingWidth, 0);
    }
    else {
        _moreSecondarySettingView.transform = CGAffineTransformIdentity;
    }
}

- (void)setHiddenLeftControlView:(BOOL)hiddenLeftControlView {
    if ( hiddenLeftControlView == _hiddenLeftControlView ) return;
    _hiddenLeftControlView = hiddenLeftControlView;
    if ( _hiddenLeftControlView ) {
        self.controlView.leftControlView.transform = CGAffineTransformMakeTranslation(-self.controlView.leftViewWidth, 0);
    }
    else {
        self.controlView.leftControlView.transform =  CGAffineTransformIdentity;
    }
}

- (SJOrentationObserver *)orentation {
    if ( _orentation ) return _orentation;
    _orentation = [[SJOrentationObserver alloc] initWithTarget:_presentView container:self.view];
    __weak typeof(self) _self = self;
    _orentation.rotationCondition = ^BOOL(SJOrentationObserver * _Nonnull observer) {
        __strong typeof(_self) self = _self;
        if ( !self ) return NO;
        if ( self.stopped ) {
            if ( observer.isFullScreen ) return YES;
            else return NO;
        }
        if ( self.touchedScrollView ) return NO;
        switch ( self.state ) {
            case SJVideoPlayerPlayState_Unknown:
            case SJVideoPlayerPlayState_Prepare:
            case SJVideoPlayerPlayState_PlayFailed: return NO;
            default: break;
        }
        if ( self.playOnCell && !self.scrollIn ) return NO;
        if ( self.disableRotation ) return NO;
        if ( self.isLockedScrren ) return NO;
        return YES;
    };
    
    _orentation.orientationWillChange = ^(SJOrentationObserver * _Nonnull observer, BOOL isFullScreen) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        _sjAnima(^{
            self.hiddenMoreSecondarySettingView = YES;
            self.hiddenMoreSettingView = YES;
            self.hideControl = YES;
            if ( !observer.isFullScreen ) self.hiddenLeftControlView = YES;
            self.controlView.previewView.hidden = YES;
            if ( self.willRotateScreen ) self.willRotateScreen(self, isFullScreen);
        });
    };
    
    _orentation.orientationChanged = ^(SJOrentationObserver * _Nonnull observer, BOOL isFullScreen) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        _sjAnima_Complete(^{
            if ( observer.isFullScreen ) {
                // `iPhone_X` remake constraints.
                if ( SJ_is_iPhoneX() ) {
                    [self.controlView mas_remakeConstraints:^(MASConstraintMaker *make) {
                        make.center.offset(0);
                        make.height.equalTo(self.controlView.superview);
                        make.width.equalTo(self.controlView.mas_height).multipliedBy(16.0f / 9);
                    }];
                }
            }
            else {
                // `iPhone_X` remake constraints.
                if ( SJ_is_iPhoneX() ) {
                    [self.controlView mas_remakeConstraints:^(MASConstraintMaker *make) {
                        make.edges.equalTo(self.controlView.superview);
                    }];
                }
            }
        }, ^{
            if ( self.rotatedScreen ) self.rotatedScreen(self, observer.isFullScreen);
        });
    };
    
    return _orentation;
}

- (SJVideoPlayerRegistrar *)registrar {
    if ( _registrar ) return _registrar;
    _registrar = [SJVideoPlayerRegistrar new];
    
    __weak typeof(self) _self = self;
    _registrar.willResignActive = ^(SJVideoPlayerRegistrar * _Nonnull registrar) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        self.lockScreen = YES;
        [self _pause];
    };
    
    _registrar.didBecomeActive = ^(SJVideoPlayerRegistrar * _Nonnull registrar) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        self.lockScreen = NO;
        if ( self.playOnCell && !self.scrollIn ) return;
        if ( self.state == SJVideoPlayerPlayState_PlayEnd ||
             self.state == SJVideoPlayerPlayState_Unknown ||
             self.state == SJVideoPlayerPlayState_PlayFailed ) return;
        if ( !self.userClickedPause ) [self play];
    };
    
    _registrar.oldDeviceUnavailable = ^(SJVideoPlayerRegistrar * _Nonnull registrar) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( !self.userClickedPause ) [self play];
    };
    
    //    _registrar.categoryChange = ^(SJVideoPlayerRegistrar * _Nonnull registrar) {
    //        __strong typeof(_self) self = _self;
    //        if ( !self ) return;
    //
    //    };
    
    return _registrar;
}

- (SJVolBrigControl *)volBrig {
    if ( _volBrigControl ) return _volBrigControl;
    _volBrigControl  = [SJVolBrigControl new];
    __weak typeof(self) _self = self;
    _volBrigControl.volumeChanged = ^(float volume) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( self.moreSettingFooterViewModel.volumeChanged ) self.moreSettingFooterViewModel.volumeChanged(volume);
    };
    
    _volBrigControl.brightnessChanged = ^(float brightness) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( self.moreSettingFooterViewModel.brightnessChanged ) self.moreSettingFooterViewModel.brightnessChanged(self.volBrigControl.brightness);
    };
    
    return _volBrigControl;
}

- (SJVideoPlayerDraggingProgressView *)draggingProgressView {
    if ( _draggingProgressView ) return _draggingProgressView;
    _draggingProgressView = [[SJVideoPlayerDraggingProgressView alloc] initWithOrentationObserver:self.orentation];
    return _draggingProgressView;
}

- (void)gesturesHandleWithTargetView:(UIView *)targetView {
    
    _gestureControl = [[SJPlayerGestureControl alloc] initWithTargetView:targetView];
    
    __weak typeof(self) _self = self;
    _gestureControl.triggerCondition = ^BOOL(SJPlayerGestureControl * _Nonnull control, UIGestureRecognizer *gesture) {
        __strong typeof(_self) self = _self;
        if ( !self ) return NO;
        if ( self.isLockedScrren ) return NO;
        CGPoint point = [gesture locationInView:gesture.view];
        if ( CGRectContainsPoint(self.moreSettingView.frame, point) ||
            CGRectContainsPoint(self.moreSecondarySettingView.frame, point) ||
            CGRectContainsPoint(self.controlView.previewView.frame, point) ) {
            return NO;
        }
        if ( [gesture isKindOfClass:[UIPanGestureRecognizer class]] &&
            self.playOnCell &&
            !self.orentation.fullScreen ) return NO;
        else return YES;
    };
    
    _gestureControl.singleTapped = ^(SJPlayerGestureControl * _Nonnull control) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        _sjAnima(^{
            if ( !self.hiddenMoreSettingView ) {
                self.hiddenMoreSettingView = YES;
            }
            else if ( !self.hiddenMoreSecondarySettingView ) {
                self.hiddenMoreSecondarySettingView = YES;
            }
            else {
                self.hideControl = !self.isHiddenControl;
            }
        });
    };
    
    _gestureControl.doubleTapped = ^(SJPlayerGestureControl * _Nonnull control) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        switch (self.state) {
            case SJVideoPlayerPlayState_Unknown:
            case SJVideoPlayerPlayState_Prepare:
                break;
            case SJVideoPlayerPlayState_Buffing:
            case SJVideoPlayerPlayState_Playing: {
                [self pause];
                self.userClickedPause = YES;
            }
                break;
            case SJVideoPlayerPlayState_Pause: {
                [self play];
            }
                break;
            case SJVideoPlayerPlayState_PlayEnd: {
                [self jumpedToTime:0 completionHandler:^(BOOL finished) {
                   [self play];
                }];
            }
                break;
            case SJVideoPlayerPlayState_PlayFailed:
                break;
        }
    };
    
    _gestureControl.beganPan = ^(SJPlayerGestureControl * _Nonnull control, SJPanDirection direction, SJPanLocation location) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        switch (direction) {
            case SJPanDirection_H: {
                [self _pause];
                _sjAnima(^{
                    _sjShowViews(@[self.draggingProgressView]);
                    self.hideControl = YES;
                });
                self.draggingProgressView.progress = self.asset.progress;
            }
                break;
            case SJPanDirection_V: {
                switch (location) {
                    case SJPanLocation_Right: break;
                    case SJPanLocation_Left: {
                        [[UIApplication sharedApplication].keyWindow addSubview:self.volBrigControl.brightnessView];
                        [self.volBrigControl.brightnessView mas_remakeConstraints:^(MASConstraintMaker *make) {
                            make.size.mas_offset(CGSizeMake(155, 155));
                            make.center.equalTo([UIApplication sharedApplication].keyWindow);
                        }];
                        self.volBrigControl.brightnessView.transform = self.controlView.superview.transform;
                        _sjAnima(^{
                            _sjShowViews(@[self.volBrigControl.brightnessView]);
                        });
                    }
                        break;
                    case SJPanLocation_Unknown: break;
                }
            }
                break;
            case SJPanDirection_Unknown:
                break;
        }
    };
    
    _gestureControl.changedPan = ^(SJPlayerGestureControl * _Nonnull control, SJPanDirection direction, SJPanLocation location, CGPoint translate) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        switch (direction) {
            case SJPanDirection_H: {
                _sjAnima(^{
                    self.hideControl = YES;
                });
                self.draggingProgressView.progress += translate.x * 0.003;
            }
                break;
            case SJPanDirection_V: {
                switch (location) {
                    case SJPanLocation_Left: {
                        CGFloat value = self.volBrigControl.brightness - translate.y * 0.006;
                        if ( value < 1.0 / 16 ) value = 1.0 / 16;
                        self.volBrigControl.brightness = value;
                    }
                        break;
                    case SJPanLocation_Right: {
                        CGFloat value = translate.y * 0.008;
                        self.volBrigControl.volume -= value;
                    }
                        break;
                    case SJPanLocation_Unknown: break;
                }
            }
                break;
            default:
                break;
        }
    };
    
    _gestureControl.endedPan = ^(SJPlayerGestureControl * _Nonnull control, SJPanDirection direction, SJPanLocation location) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        switch ( direction ) {
            case SJPanDirection_H:{
                _sjAnima(^{
                    _sjHiddenViews(@[self.draggingProgressView]);
                });
                [self jumpedToTime:self.draggingProgressView.progress * self.asset.duration completionHandler:^(BOOL finished) {
                    __strong typeof(_self) self = _self;
                    if ( !self ) return;
                    [self play];
                }];
            }
                break;
            case SJPanDirection_V:{
                if ( location == SJPanLocation_Left ) {
                    _sjAnima(^{
                        __strong typeof(_self) self = _self;
                        if ( !self ) return;
                        _sjHiddenViews(@[self.volBrigControl.brightnessView]);
                    });
                }
            }
                break;
            case SJPanDirection_Unknown: break;
        }
    };
    
    _gestureControl.pinched = ^(SJPlayerGestureControl * _Nonnull control, float scale) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( scale > 1 ) {
            self.presentView.videoGravity = AVLayerVideoGravityResizeAspectFill;
        }
        else {
            self.presentView.videoGravity = AVLayerVideoGravityResizeAspect;
        }
    };
}


#pragma mark ======================================================

- (void)sliderWillBeginDragging:(SJSlider *)slider {
    switch (slider.tag) {
        case SJVideoPlaySliderTag_Progress: {
            [self _pause];
            NSInteger currentTime = slider.value * self.asset.duration;
            [self _refreshingTimeLabelWithCurrentTime:currentTime duration:self.asset.duration];
            _sjAnima(^{
                self.hideControl = YES;
                _sjShowViews(@[self.draggingProgressView]);
            });
            [self _cancelDelayHiddenControl];
            self.draggingProgressView.progress = slider.value;
        }
            break;
            
        default:
            break;
    }
}

- (void)sliderDidDrag:(SJSlider *)slider {
    switch (slider.tag) {
        case SJVideoPlaySliderTag_Progress: {
            NSInteger currentTime = slider.value * self.asset.duration;
            [self _refreshingTimeLabelWithCurrentTime:currentTime duration:self.asset.duration];
            self.draggingProgressView.progress = slider.value;
        }
            break;
            
        default:
            break;
    }
}

- (void)sliderDidEndDragging:(SJSlider *)slider {
    switch (slider.tag) {
        case SJVideoPlaySliderTag_Progress: {
            NSInteger currentTime = slider.value * self.asset.duration;
            __weak typeof(self) _self = self;
            [self jumpedToTime:currentTime completionHandler:^(BOOL finished) {
                __strong typeof(_self) self = _self;
                if ( !self ) return;
                [self play];
                [self _delayHiddenControl];
            }];
        }
            break;
            
        default:
            break;
    }
}

#pragma mark ======================================================

- (void)controlView:(SJVideoPlayerControlView *)controlView clickedBtnTag:(SJVideoPlayControlViewTag)tag {
    switch (tag) {
        case SJVideoPlayControlViewTag_Back: {
            if ( self.orentation.isFullScreen ) {
                if ( self.disableRotation ) return;
                else [self.orentation _changeOrientation];
            }
            else {
                if ( self.clickedBackEvent ) self.clickedBackEvent(self);
            }
        }
            break;
        case SJVideoPlayControlViewTag_Full: {
            [self.orentation _changeOrientation];
        }
            break;
            
        case SJVideoPlayControlViewTag_Play: {
            [self play];
            self.userClickedPause = NO;
        }
            break;
        case SJVideoPlayControlViewTag_Pause: {
            [self pause];
            self.userClickedPause = YES;
        }
            break;
        case SJVideoPlayControlViewTag_Replay: {
            _sjAnima(^{
                if ( !self.isLockedScrren ) self.hideControl = NO;
            });
            [self jumpedToTime:0 completionHandler:^(BOOL finished) {
                [self play];
            }];
        }
            break;
        case SJVideoPlayControlViewTag_Preview: {
            [self _cancelDelayHiddenControl];
            _sjAnima(^{
                self.controlView.previewView.hidden = !self.controlView.previewView.isHidden;
            });
        }
            break;
        case SJVideoPlayControlViewTag_Lock: {
            // 解锁
            self.lockScreen = NO;
        }
            break;
        case SJVideoPlayControlViewTag_Unlock: {
            // 锁屏
            self.lockScreen = YES;
            [self showTitle:@"已锁定"];
        }
            break;
        case SJVideoPlayControlViewTag_LoadFailed: {
            self.asset = [[SJVideoPlayerAssetCarrier alloc] initWithAssetURL:self.asset.assetURL beginTime:self.asset.beginTime scrollView:self.asset.scrollView indexPath:self.asset.indexPath superviewTag:self.asset.superviewTag];
        }
            break;
        case SJVideoPlayControlViewTag_More: {
            _sjAnima(^{
                self.hiddenMoreSettingView = NO;
                self.hideControl = YES;
            });
        }
            break;
    }
}

- (void)controlView:(SJVideoPlayerControlView *)controlView didSelectPreviewItem:(SJVideoPreviewModel *)item {
    [self _pause];
    __weak typeof(self) _self = self;
    [self seekToTime:item.localTime completionHandler:^(BOOL finished) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        [self play];
    }];
}

#pragma mark

- (void)_itemPrepareToPlay {
    [self _startLoading];
    self.hideControl = YES;
    self.userClickedPause = NO;
    self.hiddenMoreSettingView = YES;
    self.hiddenMoreSecondarySettingView = YES;
    self.controlView.bottomProgressSlider.value = 0;
    self.controlView.bottomProgressSlider.bufferProgress = 0;
    if ( self.moreSettingFooterViewModel.volumeChanged ) {
        self.moreSettingFooterViewModel.volumeChanged(self.volBrigControl.volume);
    }
    if ( self.moreSettingFooterViewModel.brightnessChanged ) {
        self.moreSettingFooterViewModel.brightnessChanged(self.volBrigControl.brightness);
    }
    [self _prepareState];
}

- (void)_itemPlayFailed {
    [self _stopLoading];
    [self _playFailedState];
    self.error = self.asset.playerItem.error;
    _sjErrorLog(self.error);
}

- (void)_itemReadyToPlay {
    _sjAnima(^{
        self.hideControl = NO;
    });

    if ( self.autoplay && !self.userClickedPause && !self.suspend ) {
        [self play];
    }
    
    if ( 0 != self.URLAsset.title.length ) {
        self.controlView.topControlView.titleLabel.attributedText = sj_makeAttributesString(^(SJAttributeWorker * _Nonnull make) {
            make.insert(self.URLAsset.title, 0);
            make.font([SJVideoPlayerSettings commonSettings].titleFont).textColor([SJVideoPlayerSettings commonSettings].titleColor);
            make.shadow(CGSizeMake(0.5, 0.5), 1, [UIColor blackColor]);
        });
    }
    else self.controlView.topControlView.titleLabel.attributedText = nil;
}

- (void)_refreshingTimeLabelWithCurrentTime:(NSTimeInterval)currentTime duration:(NSTimeInterval)duration {
    self.controlView.bottomControlView.currentTimeLabel.text = [self.asset timeString:currentTime];
    self.controlView.bottomControlView.durationTimeLabel.text = [self.asset timeString:duration];
}

- (void)_refreshingTimeProgressSliderWithCurrentTime:(NSTimeInterval)currentTime duration:(NSTimeInterval)duration {
    CGFloat value = currentTime / duration;
    [self.controlView.bottomProgressSlider setValue:value animated:YES];
    [self.controlView.bottomControlView.progressSlider setValue:value animated:NO];
}

- (void)_itemPlayEnd {
    [self _pause];
//    [self jumpedToTime:0 completionHandler:nil];
    [self _playEndState];
}

- (void)_play {
    [self _stopLoading];
    [self.asset.player play];
    self.asset.player.rate = self.rate;
    self.moreSettingFooterViewModel.playerRateChanged(self.rate);
}

- (void)_pause {
    [self.asset.player pause];
}

- (void)_startLoading {
    if ( _loadingView.isAnimating ) return;
    [_loadingView start];
}

- (void)_stopLoading {
    if ( !_loadingView.isAnimating ) return;
    [_loadingView stop];
}

- (void)_buffering {
    if ( !self.asset ||
         self.userClickedPause ||
         self.state == SJVideoPlayerPlayState_PlayFailed ||
         self.state == SJVideoPlayerPlayState_PlayEnd ||
         self.state == SJVideoPlayerPlayState_Unknown ||
         self.state == SJVideoPlayerPlayState_Playing ) return;

    [self _startLoading];
    [self _pause];
    self.state = SJVideoPlayerPlayState_Buffing;
    __weak typeof(self) _self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        if ( !self.asset ||
             self.userClickedPause ||
             self.state == SJVideoPlayerPlayState_PlayFailed ||
             self.state == SJVideoPlayerPlayState_PlayEnd ||
             self.state == SJVideoPlayerPlayState_Unknown ||
             self.state == SJVideoPlayerPlayState_Playing ) return;

        if ( !self.asset.playerItem.isPlaybackLikelyToKeepUp ) {
            [self _buffering];
        }
        else {
            [self _stopLoading];
            if ( !self.suspend ) [self play];
        }
    });
}

- (void)setState:(SJVideoPlayerPlayState)state {
    if ( state == _state ) return;
    _state = state;
    _presentView.state = state;
}

#pragma mark - asset
- (void)setAsset:(SJVideoPlayerAssetCarrier *)asset {
    [self _clear];
    _asset = asset;
    if ( !asset || !asset.assetURL ) return;
    [self resetRate];
    _view.alpha = 1;
    _presentView.asset = asset;
    _controlView.asset = asset;
    _draggingProgressView.asset = asset;
    
    [self _itemPrepareToPlay];
    
    __weak typeof(self) _self = self;
    
    asset.playerItemStateChanged = ^(SJVideoPlayerAssetCarrier * _Nonnull asset, AVPlayerItemStatus status) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( self.state == SJVideoPlayerPlayState_PlayEnd ) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            switch (status) {
                case AVPlayerItemStatusUnknown: break;
                case AVPlayerItemStatusFailed: {
                    [self _itemPlayFailed];
                }
                    break;
                case AVPlayerItemStatusReadyToPlay: {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        __strong typeof(_self) self = _self;
                        if ( !self ) return ;
                        [self _itemReadyToPlay];
                    });
                }
                    break;
            }
        });
        
    };
    
    asset.playTimeChanged = ^(SJVideoPlayerAssetCarrier * _Nonnull asset, NSTimeInterval currentTime, NSTimeInterval duration) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        [self _refreshingTimeProgressSliderWithCurrentTime:currentTime duration:duration];
        [self _refreshingTimeLabelWithCurrentTime:currentTime duration:duration];
    };
    
    asset.playDidToEnd = ^(SJVideoPlayerAssetCarrier * _Nonnull asset) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        [self _itemPlayEnd];
        if ( self.playDidToEnd ) self.playDidToEnd(self);
    };
    
    asset.loadedTimeProgress = ^(float progress) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        self.controlView.bottomControlView.progressSlider.bufferProgress = progress;
    };
    
    asset.beingBuffered = ^(BOOL state) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( self.state == SJVideoPlayerPlayState_Buffing ) return;
        [self _buffering];
    };
    
    if ( asset.indexPath ) {
        /// 默认滑入
        self.scrollIn = YES;
    }
    else {
        self.scrollIn = NO;
    }
    
    // scroll view
    if ( asset.scrollView ) {
        /// 滑入
        asset.scrollIn = ^(SJVideoPlayerAssetCarrier * _Nonnull asset, UIView * _Nonnull superview) {
            __strong typeof(_self) self = _self;
            if ( !self ) return;
            if ( self.scrollIn ) return;
            self.scrollIn = YES;
            self.hideControl = NO;
            self.view.alpha = 1;
            if ( superview && self.view.superview != superview ) {
                [self.view removeFromSuperview];
                [superview addSubview:self.view];
                [self.view mas_remakeConstraints:^(MASConstraintMaker *make) {
                    make.edges.equalTo(self.view.superview);
                }];
            }
            //            if ( !self.userPaused &&
            //                 self.state != SJVideoPlayerPlayState_PlayEnd ) [self play];
        };
        
        /// 滑出
        asset.scrollOut = ^(SJVideoPlayerAssetCarrier * _Nonnull asset) {
            __strong typeof(_self) self = _self;
            if ( !self ) return;
            if ( !self.scrollIn ) return;
            self.scrollIn = NO;
            self.view.alpha = 0.001;
            if ( !self.userPaused &&
                self.state != SJVideoPlayerPlayState_PlayEnd ) [self pause];
        };
        
        ///
        asset.touchedScrollView = ^(SJVideoPlayerAssetCarrier * _Nonnull asset, BOOL tracking) {
            __strong typeof(_self) self = _self;
            if ( !self ) return;
            self.touchedScrollView = tracking;
        };
    }
}

- (SJVideoPlayerAssetCarrier *)asset {
    return _asset;
}

- (void)_clear {
    _presentView.asset = nil;
    _controlView.asset = nil;
    _asset = nil;
}
@end


#pragma mark - 播放

@implementation SJVideoPlayer (Play)

- (void)setURLAsset:(SJVideoPlayerURLAsset *)URLAsset {
    objc_setAssociatedObject(self, @selector(URLAsset), URLAsset, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self setAsset:[URLAsset valueForKey:kSJVideoPlayerAssetKey]];
}

- (SJVideoPlayerURLAsset *)URLAsset {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)playWithURL:(NSURL *)playURL {
    [self playWithURL:playURL jumpedToTime:0];
}

// unit: sec.
- (void)playWithURL:(NSURL *)playURL jumpedToTime:(NSTimeInterval)time {
    self.URLAsset = [[SJVideoPlayerURLAsset alloc] initWithAssetURL:playURL beginTime:time];
}

- (void)setAssetURL:(NSURL *)assetURL {
    [self playWithURL:assetURL jumpedToTime:0];
}

- (NSURL *)assetURL {
    return self.asset.assetURL;
}

- (UIImage *)screenshot {
    return [_asset screenshot];
}

- (NSTimeInterval)currentTime {
    return _asset.currentTime;
}

- (NSTimeInterval)totalTime {
    return _asset.duration;
}

@end


#pragma mark - 控制

@implementation SJVideoPlayer (Control)

- (BOOL)userPaused {
    return self.userClickedPause;
}

- (void)setAutoplay:(BOOL)autoplay {
    objc_setAssociatedObject(self, @selector(isAutoplay), @(autoplay), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)isAutoplay {
    return [objc_getAssociatedObject(self, _cmd) boolValue];
}

- (BOOL)play {
    self.suspend = NO;
    self.stopped = NO;
    
    if ( !self.asset ) return NO;
    self.userClickedPause = NO;
    _sjAnima(^{
        [self _playState];
    });
    [self _play];
    return YES;
}

- (BOOL)pause {
    self.suspend = YES;
    
    if ( !self.asset ) return NO;
    _sjAnima(^{
        [self _pauseState];
        self.hideControl = NO;
    });
    [self _pause];
    if ( !self.playOnCell || self.orentation.fullScreen ) [self showTitle:@"已暂停"];
    return YES;
}

- (void)stop {
    self.suspend = NO;
    self.stopped = YES;
    
    if ( !self.asset ) return;
    _sjAnima(^{
        [self _unknownState];
    });
    [self _clear];
}

- (void)stopAndFadeOut {
    self.suspend = NO;
    self.stopped = YES;
    // state
    _sjAnima(^{
        [self _unknownState];
    });
    // pause
    [self _pause];
    // fade out
    [UIView animateWithDuration:0.5 animations:^{
        self.view.alpha = 0.001;
    } completion:^(BOOL finished) {
        [self stop];
        [_view removeFromSuperview];
    }];
}

- (void)setPlayDidToEnd:(void (^)(SJVideoPlayer * _Nonnull))playDidToEnd {
    objc_setAssociatedObject(self, @selector(playDidToEnd), playDidToEnd, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (void (^)(SJVideoPlayer * _Nonnull))playDidToEnd {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)jumpedToTime:(NSTimeInterval)time completionHandler:(void (^ __nullable)(BOOL finished))completionHandler {
    if ( isnan(time) ) { return;}
    CMTime seekTime = CMTimeMakeWithSeconds(time, NSEC_PER_SEC);
    [self seekToTime:seekTime completionHandler:completionHandler];
}

- (void)seekToTime:(CMTime)time completionHandler:(void (^ __nullable)(BOOL finished))completionHandler {
    [self _startLoading];
    __weak typeof(self) _self = self;
    [self.asset seekToTime:time completionHandler:^(BOOL finished) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        [self _stopLoading];
        if ( completionHandler ) completionHandler(finished);
    }];
}

- (void)stopRotation {
    self.disableRotation = YES;
}

- (void)enableRotation {
    self.disableRotation = NO;
}

@end


#pragma mark - 配置

@implementation SJVideoPlayer (Setting)

- (void)setClickedBackEvent:(void (^)(SJVideoPlayer *player))clickedBackEvent {
    objc_setAssociatedObject(self, @selector(clickedBackEvent), clickedBackEvent, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (void (^)(SJVideoPlayer * _Nonnull))clickedBackEvent {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setMoreSettings:(NSArray<SJVideoPlayerMoreSetting *> *)moreSettings {
    objc_setAssociatedObject(self, @selector(moreSettings), moreSettings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableSet<SJVideoPlayerMoreSetting *> *moreSettingsM = [NSMutableSet new];
    [moreSettings enumerateObjectsUsingBlock:^(SJVideoPlayerMoreSetting * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [self _addSetting:obj container:moreSettingsM];
    }];
    
    [moreSettingsM enumerateObjectsUsingBlock:^(SJVideoPlayerMoreSetting * _Nonnull obj, BOOL * _Nonnull stop) {
        [self _dressSetting:obj];
    }];
    self.moreSettingView.moreSettings = moreSettings;
}

- (void)_addSetting:(SJVideoPlayerMoreSetting *)setting container:(NSMutableSet<SJVideoPlayerMoreSetting *> *)moreSttingsM {
    [moreSttingsM addObject:setting];
    if ( !setting.showTowSetting ) return;
    [setting.twoSettingItems enumerateObjectsUsingBlock:^(SJVideoPlayerMoreSettingSecondary * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [self _addSetting:(SJVideoPlayerMoreSetting *)obj container:moreSttingsM];
    }];
}

- (void)_dressSetting:(SJVideoPlayerMoreSetting *)setting {
    if ( !setting.clickedExeBlock ) return;
    void(^clickedExeBlock)(SJVideoPlayerMoreSetting *model) = [setting.clickedExeBlock copy];
    __weak typeof(self) _self = self;
    if ( setting.isShowTowSetting ) {
        setting.clickedExeBlock = ^(SJVideoPlayerMoreSetting * _Nonnull model) {
            clickedExeBlock(model);
            __strong typeof(_self) self = _self;
            if ( !self ) return;
            self.moreSecondarySettingView.twoLevelSettings = model;
            _sjAnima(^{
                self.hiddenMoreSettingView = YES;
                self.hiddenMoreSecondarySettingView = NO;
            });
        };
        return;
    }
    
    setting.clickedExeBlock = ^(SJVideoPlayerMoreSetting * _Nonnull model) {
        clickedExeBlock(model);
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        _sjAnima(^{
            self.hiddenMoreSettingView = YES;
            if ( !model.isShowTowSetting ) self.hiddenMoreSecondarySettingView = YES;
        });
    };
}

- (NSArray<SJVideoPlayerMoreSetting *> *)moreSettings {
    return objc_getAssociatedObject(self, _cmd);
}

- (SJVideoPlayerSettings *)commonSettings {
    return [SJVideoPlayerSettings commonSettings];
}

+ (void (^)(void (^ _Nonnull)(SJVideoPlayerSettings * _Nonnull)))update {
    return ^ (void(^block)(SJVideoPlayerSettings *settings)) {
        [self _addOperation:^ {
            if ( !block ) return;
            block([SJVideoPlayerSettings commonSettings]);
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:SJSettingsPlayerNotification
                                                                    object:[SJVideoPlayerSettings commonSettings]];
            });
        }];
    };
}

+ (void)resetSetting {
    [[SJVideoPlayerSettings commonSettings] reset];
}

- (void)setPlaceholder:(UIImage *)placeholder {
    SJVideoPlayer.update(^(SJVideoPlayerSettings * _Nonnull commonSettings) {
        commonSettings.placeholder = placeholder;
    });
}

- (void)setGeneratePreviewImages:(BOOL)generatePreviewImages {
    objc_setAssociatedObject(self, @selector(generatePreviewImages), @(generatePreviewImages), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)generatePreviewImages {
    return [objc_getAssociatedObject(self, _cmd) boolValue];
}

@end



#pragma mark - 调速

@implementation SJVideoPlayer (Rate)

- (void)setRate:(float)rate {
    if ( self.rate == rate ) return;
    objc_setAssociatedObject(self, @selector(rate), @(rate), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ( !self.asset ) return;
    self.userClickedPause = NO;
    _sjAnima(^{
        [self _playState];
    });
    self.asset.player.rate = rate;
    if ( self.moreSettingFooterViewModel.playerRateChanged ) self.moreSettingFooterViewModel.playerRateChanged(rate);
    if ( self.rateChanged ) self.rateChanged(self);
}

- (float)rate {
    return [objc_getAssociatedObject(self, _cmd) floatValue];
}

- (void)resetRate {
    objc_setAssociatedObject(self, @selector(rate), @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)setRateChanged:(void (^)(SJVideoPlayer * _Nonnull))rateChanged {
    objc_setAssociatedObject(self, @selector(rateChanged), rateChanged, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (void (^)(SJVideoPlayer * _Nonnull))rateChanged {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setInternallyChangedRate:(void (^)(SJVideoPlayer * _Nonnull, float))internallyChangedRate {
    objc_setAssociatedObject(self, @selector(internallyChangedRate), internallyChangedRate, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (void (^)(SJVideoPlayer * _Nonnull, float))internallyChangedRate {
    return objc_getAssociatedObject(self, _cmd);
}

@end


#pragma mark - 屏幕旋转

@implementation SJVideoPlayer (Rotation)

- (void)setDisableRotation:(BOOL)disableRotation {
    objc_setAssociatedObject(self, @selector(disableRotation), @(disableRotation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)disableRotation {
    return [objc_getAssociatedObject(self, _cmd) boolValue];
}

- (void)setWillRotateScreen:(void (^)(SJVideoPlayer * _Nonnull, BOOL))willRotateScreen {
    objc_setAssociatedObject(self, @selector(willRotateScreen), willRotateScreen, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (void (^)(SJVideoPlayer * _Nonnull, BOOL))willRotateScreen {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setRotatedScreen:(void (^)(SJVideoPlayer * _Nonnull, BOOL))rotatedScreen {
    objc_setAssociatedObject(self, @selector(rotatedScreen), rotatedScreen, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (void (^)(SJVideoPlayer * _Nonnull, BOOL))rotatedScreen {
    return objc_getAssociatedObject(self, _cmd);
}

- (BOOL)isFullScreen {
    return self.orentation.isFullScreen;
}

@end


#pragma mark - 控制视图

@implementation SJVideoPlayer (ControlView)

- (void)setControlViewDisplayStatus:(void (^)(SJVideoPlayer * _Nonnull, BOOL))controlViewDisplayStatus {
    objc_setAssociatedObject(self, @selector(controlViewDisplayStatus), controlViewDisplayStatus, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (void (^)(SJVideoPlayer * _Nonnull, BOOL))controlViewDisplayStatus {
    return objc_getAssociatedObject(self, _cmd);
}

- (BOOL)controlViewDisplayed {
    return !self.isHiddenControl;
}

@end


#pragma mark - 提示

@implementation SJVideoPlayer (Prompt)

- (SJPrompt *)prompt {
    SJPrompt *prompt = objc_getAssociatedObject(self, _cmd);
    if ( prompt ) return prompt;
    prompt = [SJPrompt promptWithPresentView:_presentView];
    prompt.update(^(SJPromptConfig * _Nonnull config) {
        config.cornerRadius = 4;
        config.font = [UIFont systemFontOfSize:12];
    });
    objc_setAssociatedObject(self, _cmd, prompt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return prompt;
}

- (void)showTitle:(NSString *)title {
    [self showTitle:title duration:1];
}

- (void)showTitle:(NSString *)title duration:(NSTimeInterval)duration {
    [self.prompt showTitle:title duration:duration];
}

- (void)hiddenTitle {
    [self.prompt hidden];
}

@end

//
//  CLiAdManager.m
//  CodexLib iAdManager
//
//  Created by 7thCodex Software (William Patterson) on 1/15/13.
//  Copyright: open source, freely usable for any purpose provided you retain this header
//             and distribute license file with source.
//  GitHub: https://github.com/billpatterson/Codex-iAdManager
//
//
//  Useage: Access (and implicitly create) an instance by calling [CLiAdManager sharedManager]
//
//          Add any Container view controllers you wish the manager to monitor (automatically
//            sending ads to any content controllers the container controller manages):
//            [[CLiAdManager sharedManager] monitorNavigationController:navCtrl]
//            [[CLiAdManager sharedManager] monitorTabBarController:tabCtrl]
//
//          To remove any container controller from monitoring, tell the manger to remove it:
//            [[CLiAdManager sharedManager] stopMonitoringNavigationController:navCtrl]
//            [[CLiAdManager sharedManager] stopMonitoringTabBarController:tabCtrl]
//
//          To completely turn off the Ad Manager and stop sending of all ads:
//            [[CLiAdManager sharedManager] shutdown]
//            NOTE: there is no way to "restart" the AdManager, so only call this if you
//                  want to permanently disable action (such as in a free app that has
//                  detected ads should be removed due to an in-app purchase, for instance).
//
//          To temporarily suspend display of any ads, then turn it back on agin, call:
//            [[CLiAdManager sharedManager] suspend:YES]
//            [[CLiAdManager sharedManager] suspend:NO]
//
//          You must (of course) have the iAd framework linked into your project!
//


#import "CLiAdManager.h"


// Set to YES to enable trace logging of iAd events
#define LOG YES



// The one instance:
static CLiAdManager* _singletonCLiAdManagerInstance;



@interface CLiAdManager()
{
    BOOL _adDeliveryIsSuspended;
}

// Remember/hold the one instance of iAd view:
@property (nonatomic, strong) ADBannerView *adBannerView;


// Track the currently-up controller, so we can tell it to remove iAd when
// it goes off screen (and so we can tell it when iAd state changes to unavailable)
// Use a weak reference so that we aren't holding it in memory if it goes away.
@property (nonatomic, weak) UIViewController* lastShownViewController;


@property (nonatomic, strong) NSMutableArray* containerControllersBeingMonitored;

@property (nonatomic, weak) id<iAdDisplayer> temporaryOverrideTarget;

@end



/*
 To use this, code assumes this class is the Navigation Delegate so we get informed when new
 view controllers are coming on-screen.
 
 We also assume we are the iAd banner object delegate, so we get notices about ad availabiliity.
 
 This class combines the two, by sending ad show/remove notices to the currently visible view
 controller as iAd status updates are received.
 
 Requires that the iAd framework is linked into project!
 */


@implementation CLiAdManager


+ (CLiAdManager*) sharedManager
{
    if (!_singletonCLiAdManagerInstance)
        _singletonCLiAdManagerInstance = [[CLiAdManager alloc] init];
    return _singletonCLiAdManagerInstance;
}


- (id) init
{
    self = [super init];
    if (self) {
        [self createAdBannerView];
        self.containerControllersBeingMonitored = [NSMutableArray array];
    }
    return self;
}


- (void) shutdown
{
    for (id c in self.containerControllersBeingMonitored) {
        [c setDelegate:nil];
    }
    [self.containerControllersBeingMonitored removeAllObjects];
    self.containerControllersBeingMonitored = nil;
    self.lastShownViewController = nil;
    self.temporaryOverrideTarget = nil;
    self.adBannerView = nil;
}


- (void) dealloc
{
    [self shutdown];
}


- (void) setAdDeliveryIsSuspended:(BOOL)toSuspended
{
    if (toSuspended && !_adDeliveryIsSuspended) {
        // Suspend: remove any shown ads
        [self _hideAdInCurrentViewController];
        _adDeliveryIsSuspended = toSuspended;
    }
    if (!toSuspended && _adDeliveryIsSuspended) {
        // Resume: show add in current controller
        _adDeliveryIsSuspended = toSuspended;
        [self _sendAdToCurrentViewController];
    }
}

- (BOOL) adDeliveryIsSuspended
{
    return _adDeliveryIsSuspended;
}


#pragma mark - Container controller monitoring


- (void) monitorNavigationController:(UINavigationController*) controller
{
    if (![self.containerControllersBeingMonitored containsObject:controller]) {
        
        [self.containerControllersBeingMonitored addObject:controller];
        [controller setDelegate: self];
        
        //self.lastShownViewController = controller.topViewController;
    }
}
- (void) stopMonitoringNavigationController:(UINavigationController*) controller
{
    if ([self.containerControllersBeingMonitored containsObject:controller]) {
        controller.delegate = nil;
        [self.containerControllersBeingMonitored removeObject:controller];
    }
}


- (void) monitorTabBarController:(UITabBarController*) controller
{
    if (![self.containerControllersBeingMonitored containsObject:controller]) {
        
        [self.containerControllersBeingMonitored addObject:controller];
        [controller setDelegate: self];
        
        //self.lastShownViewController = controller.topViewController;
    }
}
- (void) stopMonitoringTabBarController:(UITabBarController*) controller
{
    if ([self.containerControllersBeingMonitored containsObject:controller]) {
        controller.delegate = nil;
        [self.containerControllersBeingMonitored removeObject:controller];
    }
}



#pragma mark - Container controller delegate calls


- (void) navigationController:(UINavigationController *)navigationController
       willShowViewController:(UIViewController *)viewController
                     animated:(BOOL)animated
{
    if (LOG) NSLog(@"CLiAdManager - notified: will show controller: %@", viewController);
    
    // Remove adBannerView from existing presentation before trying to show it in a new one
    [self _hideAdInCurrentViewController];
}


- (void) navigationController:(UINavigationController *)navigationController
        didShowViewController:(UIViewController *)viewController
                     animated:(BOOL)animated
{
    if (LOG) NSLog(@"CLiAdManager - notified: did show controller: %@", viewController);
    
    self.lastShownViewController = viewController;
    [self _sendAdToCurrentViewController];
}



- (void)tabBarController:(UITabBarController *)tabBarController
 didSelectViewController:(UIViewController *)viewController
{
    if (LOG) NSLog(@"CLiAdManager - notified: tab bar showing controller: %@", viewController);
    
    // Remove adBannerView from existing presentation before trying to show it in a new one
    [self _hideAdInCurrentViewController];
    self.lastShownViewController = viewController;
    [self _sendAdToCurrentViewController];
}



#pragma mark - "Notifications" from Modal ViewControllers


- (void) setOverrideTargetForAds:(id<iAdDisplayer>)viewController
{
    if (LOG) NSLog(@"CLiAdManager - establishing target override: %@", viewController);
    self.temporaryOverrideTarget = viewController;
    [self _sendAdToCurrentViewController];
}

- (void) removeOverrideTargetForAds
{
    if (LOG) NSLog(@"CLiAdManager - removing target override: %@", self.temporaryOverrideTarget);
    self.temporaryOverrideTarget = nil;
    [self _sendAdToCurrentViewController];
}



#pragma mark ADBannerView setup


// Instantiate the reusable iAdBannerView and set this object as its delegate
- (void) createAdBannerView
{
    if (LOG) NSLog(@"CLiAdManager - creating AdBannderView");
    // On iOS 6 ADBannerView introduces a new initializer, use it when available.
    if ([ADBannerView instancesRespondToSelector:@selector(initWithAdType:)]) {
        self.adBannerView = [[ADBannerView alloc] initWithAdType:ADAdTypeBanner];
    }
    else {
        self.adBannerView = [[ADBannerView alloc] init];
    }
    
    // Note: as of iOS 6, doing anything specify size of ads is deprecated, handled internally by iAd.
    //       thus, we have no configuration to do on our ad objct.
    
    self.adBannerView.delegate = self;
}



#pragma mark ADBannerView delegate calls


- (void) bannerViewWillLoadAd:(ADBannerView *)banner
{
    if (LOG) NSLog(@"CLiAdManager - bannerViewWillLoadAd: %@", banner);
    // Do nothing. Ad has not yet loaded, is not ready for display.
    // Placeholder in case code needs to be added here in the future for some purpose.
}

- (void)bannerViewDidLoadAd:(ADBannerView *)banner
{
    if (LOG) NSLog(@"CLiAdManager - bannerViewDidLoadAd: %@", banner);
    // Ignore banner parameter. We have only one iAd object, so it has to be that one.
    
    [self _sendAdToCurrentViewController];
}

- (void)bannerView:(ADBannerView *)banner didFailToReceiveAdWithError:(NSError *)error
{
    // Error, or just no ad content currently available
    
    if (LOG) NSLog(@"CLiAdManager - iAd didFailToReceiveAdWithError: %@", error);
    [self _sendAdToCurrentViewController];  // Will detect that ad banner not loaded and hide it
}



#pragma mark - Send iAd To Controllers


- (void) _sendAdToCurrentViewController
{
    if (self.adDeliveryIsSuspended)
        return;
    
    // If we have a valid iAdDisplayer target, send it an ad (if valid) or a "hide" mesasge (if ad is not valid).
    
    // Determine target:
    id target = self.temporaryOverrideTarget;
    if (!target) {
        target = self.lastShownViewController;
    }
    
    // If no target or target doesn't conform to protocol, nothing to do:
    if (!target || ![target conformsToProtocol:@protocol(iAdDisplayer)]) {
        return;
    }

    if (LOG) NSLog(@"CLiAdManager - _sendAdToCurrentViewController: %@", target);
    
    id<iAdDisplayer> displayController = (id<iAdDisplayer>)target;
    
    if (self.adBannerView.bannerLoaded) {
        [displayController showAd:self.adBannerView];
    }
    else {
        [displayController hideAd:self.adBannerView];
    }
}


- (void) _hideAdInCurrentViewController
{
    if (self.adDeliveryIsSuspended)
        return;
    
    // Tell controler to hide ad (regardless of ad state)
    
    // Determine target:
    id target = self.temporaryOverrideTarget;
    if (!target) {
        target = self.lastShownViewController;
    }
    
    // If no target or target doesn't conform to protocol, nothing to do:
    if (!target || ![target conformsToProtocol:@protocol(iAdDisplayer)]) {
        return;
    }

    if (LOG) NSLog(@"CLiAdManager - _hideAdInViewController: %@", target);
    
    id<iAdDisplayer> displayController = (id<iAdDisplayer>)target;
    [displayController hideAd:self.adBannerView];

}


@end

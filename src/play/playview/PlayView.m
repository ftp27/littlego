// -----------------------------------------------------------------------------
// Copyright 2011-2014 Patrick Näf (herzbube@herzbube.ch)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// -----------------------------------------------------------------------------


// Project includes
#import "PlayView.h"
#import "layer/CrossHairLinesLayerDelegate.h"
#import "layer/CrossHairStoneLayerDelegate.h"
#import "layer/GridLayerDelegate.h"
#import "layer/StarPointsLayerDelegate.h"
#import "layer/StoneGroupStateLayerDelegate.h"
#import "layer/StonesLayerDelegate.h"
#import "layer/SymbolsLayerDelegate.h"
#import "layer/TerritoryLayerDelegate.h"
#import "layer/InfluenceLayerDelegate.h"
#import "../model/BoardPositionModel.h"
#import "../model/PlayViewMetrics.h"
#import "../model/PlayViewModel.h"
#import "../model/ScoringModel.h"
#import "../../go/GoBoard.h"
#import "../../go/GoBoardPosition.h"
#import "../../go/GoGame.h"
#import "../../go/GoPoint.h"
#import "../../go/GoScore.h"
#import "../../go/GoVertex.h"
#import "../../main/ApplicationDelegate.h"
#import "../../shared/LongRunningActionCounter.h"


// -----------------------------------------------------------------------------
/// @brief Class extension with private properties for PlayView.
// -----------------------------------------------------------------------------
@interface PlayView()
/// @name Update optimizing properties
//@{
/// @brief Is true if invocation of drawLayers() was delayed because of
/// long-running actions.
@property(nonatomic, assign) bool drawLayersWasDelayed;
//@}
/// @name Dynamically calculated properties
//@{
@property(nonatomic, assign) float crossHairPointDistanceFromFinger;
//@}
/// @name Other privately declared properties
//@{
@property(nonatomic, assign) BoardPositionModel* boardPositionModel;
@property(nonatomic, assign) PlayViewModel* playViewModel;
@property(nonatomic, assign) ScoringModel* scoringModel;
@property(nonatomic, assign) PlayViewMetrics* playViewMetrics;
/// @brief The order in which delegates appear in this array determines the
/// order in which layers are drawn.
@property(nonatomic, retain) NSMutableArray* layerDelegates;
//@}
@end


@implementation PlayView

// -----------------------------------------------------------------------------
/// @brief Initializes a PlayView object with frame rectangle @a rect. This
/// happens at least once during application launch, but may occur again later
/// on if the view is unloaded and then reloaded due to a memory warning.
///
/// @note This is the designated initializer of PlayView.
// -----------------------------------------------------------------------------
- (id) initWithFrame:(CGRect)rect
{
  // Call designated initializer of superclass (UIView)
  self = [super initWithFrame:rect];
  if (! self)
    return nil;

  ApplicationDelegate* delegate = [ApplicationDelegate sharedDelegate];
  self.boardPositionModel = delegate.boardPositionModel;
  self.playViewModel = delegate.playViewModel;
  self.scoringModel = delegate.scoringModel;
  self.playViewMetrics = delegate.playViewMetrics;
  self.layerDelegates = [[[NSMutableArray alloc] initWithCapacity:0] autorelease];

  [self setupView];

  return self;
}

// -----------------------------------------------------------------------------
/// @brief Deallocates memory allocated by this PlayView object.
// -----------------------------------------------------------------------------
- (void) dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self.boardPositionModel removeObserver:self forKeyPath:@"markNextMove"];
  [self.playViewMetrics removeObserver:self forKeyPath:@"rect"];
  [self.playViewMetrics removeObserver:self forKeyPath:@"boardSize"];
  [self.playViewMetrics removeObserver:self forKeyPath:@"displayCoordinates"];
  [self.playViewModel removeObserver:self forKeyPath:@"markLastMove"];
  [self.playViewModel removeObserver:self forKeyPath:@"moveNumbersPercentage"];
  [self.playViewModel removeObserver:self forKeyPath:@"stoneDistanceFromFingertip"];
  [self.scoringModel removeObserver:self forKeyPath:@"inconsistentTerritoryMarkupType"];
  GoBoardPosition* boardPosition = [GoGame sharedGame].boardPosition;
  [boardPosition removeObserver:self forKeyPath:@"currentBoardPosition"];
  [boardPosition removeObserver:self forKeyPath:@"numberOfBoardPositions"];

  self.playViewModel = nil;
  self.scoringModel = nil;
  self.crossHairPoint = nil;

  self.playViewMetrics = nil;
  self.layerDelegates = nil;

  [super dealloc];
}

// -----------------------------------------------------------------------------
/// @brief Sets up the view and makes it ready for drawing.
// -----------------------------------------------------------------------------
- (void) setupView
{
  self.crossHairPoint = nil;
  self.crossHairPointIsLegalMove = true;
  self.crossHairPointIsIllegalReason = GoMoveIsIllegalReasonUnknown;
  self.crossHairPointDistanceFromFinger = 0;

  self.drawLayersWasDelayed = false;

  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(goGameWillCreate:) name:goGameWillCreate object:nil];
  [center addObserver:self selector:@selector(goGameDidCreate:) name:goGameDidCreate object:nil];
  [center addObserver:self selector:@selector(goScoreScoringEnabled:) name:goScoreScoringEnabled object:nil];
  [center addObserver:self selector:@selector(goScoreScoringDisabled:) name:goScoreScoringDisabled object:nil];
  [center addObserver:self selector:@selector(goScoreCalculationEnds:) name:goScoreCalculationEnds object:nil];
  [center addObserver:self selector:@selector(territoryStatisticsChanged:) name:territoryStatisticsChanged object:nil];
  [center addObserver:self selector:@selector(longRunningActionEnds:) name:longRunningActionEnds object:nil];
  // KVO observing
  [self.boardPositionModel addObserver:self forKeyPath:@"markNextMove" options:0 context:NULL];
  [self.playViewMetrics addObserver:self forKeyPath:@"rect" options:0 context:NULL];
  [self.playViewMetrics addObserver:self forKeyPath:@"boardSize" options:0 context:NULL];
  [self.playViewMetrics addObserver:self forKeyPath:@"displayCoordinates" options:0 context:NULL];
  [self.playViewModel addObserver:self forKeyPath:@"markLastMove" options:0 context:NULL];
  [self.playViewModel addObserver:self forKeyPath:@"moveNumbersPercentage" options:0 context:NULL];
  [self.playViewModel addObserver:self forKeyPath:@"stoneDistanceFromFingertip" options:0 context:NULL];
  [self.scoringModel addObserver:self forKeyPath:@"inconsistentTerritoryMarkupType" options:0 context:NULL];
  GoGame* game = [GoGame sharedGame];
  if (game)
  {
    GoBoardPosition* boardPosition = game.boardPosition;
    [boardPosition addObserver:self forKeyPath:@"currentBoardPosition" options:0 context:NULL];
    [boardPosition addObserver:self forKeyPath:@"numberOfBoardPositions" options:0 context:NULL];
  }

  // One-time initialization
  [self updateCrossHairPointDistanceFromFinger];

  // Create & setup layer delegates in the order in which layers must be drawn
  id<PlayViewLayerDelegate> layerDelegate;
  layerDelegate = [[[GridLayerDelegate alloc] initWithMainView:self
                                                       metrics:self.playViewMetrics] autorelease];
  [self.layerDelegates addObject:layerDelegate];
  layerDelegate = [[[StarPointsLayerDelegate alloc] initWithMainView:self
                                                             metrics:self.playViewMetrics] autorelease];
  [self.layerDelegates addObject:layerDelegate];
  layerDelegate = [[[CrossHairLinesLayerDelegate alloc] initWithMainView:self
                                                                 metrics:self.playViewMetrics] autorelease];
  [self.layerDelegates addObject:layerDelegate];
  layerDelegate = [[[StonesLayerDelegate alloc] initWithMainView:self
                                                         metrics:self.playViewMetrics] autorelease];
  [self.layerDelegates addObject:layerDelegate];
  layerDelegate = [[[CrossHairStoneLayerDelegate alloc] initWithMainView:self
                                                                 metrics:self.playViewMetrics] autorelease];
  [self.layerDelegates addObject:layerDelegate];
  layerDelegate = [[[InfluenceLayerDelegate alloc] initWithMainView:self
                                                            metrics:self.playViewMetrics
                                                      playViewModel:self.playViewModel] autorelease];
  [self.layerDelegates addObject:layerDelegate];
  layerDelegate = [[[SymbolsLayerDelegate alloc] initWithMainView:self
                                                          metrics:self.playViewMetrics
                                                    playViewModel:self.playViewModel
                                               boardPositionModel:self.boardPositionModel] autorelease];
  [self.layerDelegates addObject:layerDelegate];
  layerDelegate = [[[TerritoryLayerDelegate alloc] initWithMainView:self
                                                            metrics:self.playViewMetrics
                                                       scoringModel:self.scoringModel] autorelease];
  [self.layerDelegates addObject:layerDelegate];
  layerDelegate = [[[StoneGroupStateLayerDelegate alloc] initWithMainView:self
                                                                  metrics:self.playViewMetrics
                                                             scoringModel:self.scoringModel] autorelease];
  [self.layerDelegates addObject:layerDelegate];
}

// -----------------------------------------------------------------------------
/// @brief Internal helper that correctly handles delayed drawing of layers.
/// PlayView methods that need a view update should invoke this helper instead
/// of drawLayers().
///
/// If no long-running actions are in progress, this helper invokes
/// drawLayers(), thus triggering the update in UIKit.
///
/// If any long-running actions are in progress, this helper sets
/// @e drawLayersWasDelayed to true.
// -----------------------------------------------------------------------------
- (void) delayedDrawLayers
{
  if ([LongRunningActionCounter sharedCounter].counter > 0)
    self.drawLayersWasDelayed = true;
  else
    [self drawLayers];
}

// -----------------------------------------------------------------------------
/// @brief Notifies all layers that they need to update now if they are dirty.
/// This marks one update cycle.
// -----------------------------------------------------------------------------
- (void) drawLayers
{
  // No game -> no board -> no drawing. This situation exists right after the
  // application has launched and the initial game is created only after a
  // small delay.
  if (! [GoGame sharedGame])
    return;
  self.drawLayersWasDelayed = false;

  // Draw layers in the order in which they appear in the layerDelegates array
  for (id<PlayViewLayerDelegate> layerDelegate in self.layerDelegates)
    [layerDelegate drawLayer];
}

// -----------------------------------------------------------------------------
/// @brief Notifies all layer delegates that @a event has occurred. The event
/// info object supplied to the delegates is @a eventInfo.
///
/// Delegates will ignore the event, or react to the event, as appropriate for
/// the layer that they manage.
// -----------------------------------------------------------------------------
- (void) notifyLayerDelegates:(enum PlayViewLayerDelegateEvent)event eventInfo:(id)eventInfo
{
  for (id<PlayViewLayerDelegate> layerDelegate in self.layerDelegates)
    [layerDelegate notify:event eventInfo:eventInfo];
}

// -----------------------------------------------------------------------------
/// @brief UIView method.
// -----------------------------------------------------------------------------
- (CGSize) intrinsicContentSize
{
  return self.playViewMetrics.rect.size;
}

// -----------------------------------------------------------------------------
/// @brief Responds to the #goGameWillCreate notification.
// -----------------------------------------------------------------------------
- (void) goGameWillCreate:(NSNotification*)notification
{
  GoGame* oldGame = [notification object];
  GoBoardPosition* oldBoardPosition = oldGame.boardPosition;
  [oldBoardPosition removeObserver:self forKeyPath:@"currentBoardPosition"];
  [oldBoardPosition removeObserver:self forKeyPath:@"numberOfBoardPositions"];
}

// -----------------------------------------------------------------------------
/// @brief Responds to the #goGameDidCreate notification.
// -----------------------------------------------------------------------------
- (void) goGameDidCreate:(NSNotification*)notification
{
  GoGame* newGame = [notification object];
  GoBoardPosition* newBoardPosition = newGame.boardPosition;
  [newBoardPosition addObserver:self forKeyPath:@"currentBoardPosition" options:0 context:NULL];
  [newBoardPosition addObserver:self forKeyPath:@"numberOfBoardPositions" options:0 context:NULL];
  [self notifyLayerDelegates:PVLDEventGoGameStarted eventInfo:nil];
  [self delayedDrawLayers];
}

// -----------------------------------------------------------------------------
/// @brief Responds to the #goScoreScoringEnabled notification.
// -----------------------------------------------------------------------------
- (void) goScoreScoringEnabled:(NSNotification*)notification
{
  [self notifyLayerDelegates:PVLDEventScoringModeEnabled eventInfo:nil];
  [self delayedDrawLayers];
}

// -----------------------------------------------------------------------------
/// @brief Responds to the #goScoreScoringDisabled notification.
// -----------------------------------------------------------------------------
- (void) goScoreScoringDisabled:(NSNotification*)notification
{
  [self notifyLayerDelegates:PVLDEventScoringModeDisabled eventInfo:nil];
  [self delayedDrawLayers];
}

// -----------------------------------------------------------------------------
/// @brief Responds to the #goScoreCalculationEnds notifications.
// -----------------------------------------------------------------------------
- (void) goScoreCalculationEnds:(NSNotification*)notification
{
  [self notifyLayerDelegates:PVLDEventScoreCalculationEnds eventInfo:nil];
  [self delayedDrawLayers];
}

// -----------------------------------------------------------------------------
/// @brief Responds to the #goScoreCalculationEnds notifications.
// -----------------------------------------------------------------------------
- (void) territoryStatisticsChanged:(NSNotification*)notification
{
  [self notifyLayerDelegates:PVLDEventTerritoryStatisticsChanged eventInfo:nil];
  [self delayedDrawLayers];
}

// -----------------------------------------------------------------------------
/// @brief Responds to the #longRunningActionEnds notification.
// -----------------------------------------------------------------------------
- (void) longRunningActionEnds:(NSNotification*)notification
{
  if (self.drawLayersWasDelayed)
    [self drawLayers];
}

// -----------------------------------------------------------------------------
/// @brief Responds to KVO notifications.
// -----------------------------------------------------------------------------
- (void) observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
  if (object == self.scoringModel)
  {
    if ([keyPath isEqualToString:@"inconsistentTerritoryMarkupType"])
    {
      if ([GoGame sharedGame].score.scoringEnabled)
      {
        [self notifyLayerDelegates:PVLDEventInconsistentTerritoryMarkupTypeChanged eventInfo:nil];
        [self delayedDrawLayers];
      }
    }
  }
  else if (object == self.boardPositionModel)
  {
    if ([keyPath isEqualToString:@"markNextMove"])
    {
      [self notifyLayerDelegates:PVLDEventMarkNextMoveChanged eventInfo:nil];
      [self delayedDrawLayers];
    }
  }
  else if (object == self.playViewMetrics)
  {
    if ([keyPath isEqualToString:@"rect"])
    {
      // Notify Auto Layout that our intrinsic size changed. This provokes a
      // frame change.
      [self invalidateIntrinsicContentSize];
      [self notifyLayerDelegates:PVLDEventRectangleChanged eventInfo:nil];
      [self delayedDrawLayers];
    }
    else if ([keyPath isEqualToString:@"boardSize"])
    {
      [self notifyLayerDelegates:PVLDEventBoardSizeChanged eventInfo:nil];
      [self delayedDrawLayers];
    }
    else if ([keyPath isEqualToString:@"displayCoordinates"])
    {
      [self notifyLayerDelegates:PVLDEventDisplayCoordinatesChanged eventInfo:nil];
      [self delayedDrawLayers];
    }
  }
  else if (object == self.playViewModel)
  {
    if ([keyPath isEqualToString:@"markLastMove"])
    {
      [self notifyLayerDelegates:PVLDEventMarkLastMoveChanged eventInfo:nil];
      [self delayedDrawLayers];
    }
    else if ([keyPath isEqualToString:@"moveNumbersPercentage"])
    {
      [self notifyLayerDelegates:PVLDEventMoveNumbersPercentageChanged eventInfo:nil];
      [self delayedDrawLayers];
    }
    else if ([keyPath isEqualToString:@"stoneDistanceFromFingertip"])
      [self updateCrossHairPointDistanceFromFinger];
  }
  else if (object == [GoGame sharedGame].boardPosition)
  {
    if ([keyPath isEqualToString:@"currentBoardPosition"])
    {
      [self notifyLayerDelegates:PVLDEventBoardPositionChanged eventInfo:nil];
      [self delayedDrawLayers];
    }
    else if ([keyPath isEqualToString:@"numberOfBoardPositions"])
    {
      [self notifyLayerDelegates:PVLDEventNumberOfBoardPositionsChanged eventInfo:nil];
      [self delayedDrawLayers];
    }
  }
}

// -----------------------------------------------------------------------------
/// @brief Updates self.crossHairPointDistanceFromFinger.
///
/// The calculation performed by this method depends on the value of the
/// "stone distance from fingertip" user preference. The value is a percentage
/// that is applied to a maximum distance of n fingertips, i.e. if the user has
/// selected the maximum distance the cross-hair stone will appear n fingertips
/// away from the actual touch point on the screen. Currently n = 3, and 1
/// fingertip is assumed to be the size of a toolbar button as per Apple's HIG.
// -----------------------------------------------------------------------------
- (void) updateCrossHairPointDistanceFromFinger
{
  if (0.0f == self.playViewModel.stoneDistanceFromFingertip)
  {
    self.crossHairPointDistanceFromFinger = 0;
  }
  else
  {
    static const float fingertipSizeInPoints = 20.0;  // toolbar button size in points
    static const float numberOfFingertips = 3.0;
    self.crossHairPointDistanceFromFinger = (fingertipSizeInPoints
                                             * numberOfFingertips
                                             * self.playViewModel.stoneDistanceFromFingertip);
  }
}

// -----------------------------------------------------------------------------
/// @brief Returns a PlayViewIntersection object for the intersection that is
/// closest to the view coordinates @a coordinates. Returns
/// PlayViewIntersectionNull if there is no "closest" intersection.
///
/// Determining "closest" works like this:
/// - If the user has turned this on in the preferences, @a coordinates are
///   adjusted so that the intersection is not directly under the user's
///   fingertip
/// - Otherwise the same rules as for PlayViewMetrics::intersectionNear:()
///   apply - see that method's documentation.
// -----------------------------------------------------------------------------
- (PlayViewIntersection) crossHairIntersectionNear:(CGPoint)coordinates
{
  coordinates.y -= self.crossHairPointDistanceFromFinger;
  return [_playViewMetrics intersectionNear:coordinates];
}

// -----------------------------------------------------------------------------
/// @brief Moves the cross-hair to the intersection identified by @a point,
/// specifying whether an actual play move at the intersection would be legal.
// -----------------------------------------------------------------------------
- (void) moveCrossHairTo:(GoPoint*)point isLegalMove:(bool)isLegalMove isIllegalReason:(enum GoMoveIsIllegalReason)illegalReason
{
  if (_crossHairPoint == point && _crossHairPointIsLegalMove == isLegalMove)
    return;

  // Update *BEFORE* self.crossHairPoint so that KVO observers that monitor
  // self.crossHairPoint get both changes at once. Don't use self to update the
  // property because we don't want observers to monitor the property via KVO.
  _crossHairPointIsLegalMove = isLegalMove;
  _crossHairPointIsIllegalReason = illegalReason;
  self.crossHairPoint = point;

  [self notifyLayerDelegates:PVLDEventCrossHairChanged eventInfo:point];
  [self delayedDrawLayers];
}

// -----------------------------------------------------------------------------
/// @brief Returns a PlayViewIntersection object for the intersection that is
/// closest to the view coordinates @a coordinates. Returns
/// PlayViewIntersectionNull if there is no "closest" intersection.
///
/// @see PlayViewMetrics::intersectionNear:() for details.
// -----------------------------------------------------------------------------
- (PlayViewIntersection) intersectionNear:(CGPoint)coordinates
{
  return [_playViewMetrics intersectionNear:coordinates];
}

@end

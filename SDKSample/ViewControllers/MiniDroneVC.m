//
//  MiniDroneVC.m
//  SDKSample
//

#import "MiniDroneVC.h"
#import "MiniDrone.h"
#import "H264VideoView.h"
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>

typedef enum ObservationLocation {
    TopLeft,
    Left,
    BottomLeft,
    Top,
    Center,
    Bottom,
    TopRight,
    Right,
    BottomRight
} ObservationLocation;

typedef enum ObservationDistance {
    Far,
    Acceptable,
    Close
} ObservationDistance;

@interface MiniDroneVC ()<MiniDroneDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) UIAlertView *connectionAlertView;
@property (nonatomic, strong) UIAlertController *downloadAlertController;
@property (nonatomic, strong) UIProgressView *downloadProgressView;
@property (nonatomic, strong) MiniDrone *miniDrone;
@property (nonatomic) dispatch_semaphore_t stateSem;

@property (nonatomic, assign) NSUInteger nbMaxDownload;
@property (nonatomic, assign) int currentDownloadIndex; // from 1 to nbMaxDownload

@property (nonatomic, strong) IBOutlet H264VideoView *videoView;
@property (weak, nonatomic) IBOutlet UIView *cameraView;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDevice *rearCamera;
@property (nonatomic, strong) AVCaptureDeviceInput *rearCameraInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoPreviewOutput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *videoPreviewLayer;

@property (nonatomic, strong) IBOutlet UILabel *batteryLabel;
@property (nonatomic, strong) IBOutlet UIButton *takeOffLandBt;
@property (nonatomic, strong) IBOutlet UIButton *downloadMediasBt;
@property (weak, nonatomic) IBOutlet UISlider *powerSlider;
@property (weak, nonatomic) IBOutlet UILabel *powerLabel;
@property (weak, nonatomic) IBOutlet UITextField *stickyTimeTextField;

@property (weak, nonatomic) IBOutlet UILabel *directionLabel;
@property (weak, nonatomic) IBOutlet UILabel *distanceLabel;

@property (nonatomic) ObservationLocation observationLocation;
@property (weak, nonatomic) IBOutlet UISwitch *navigateToCenterSwitch;
@property (nonatomic) ObservationDistance observationDistance;
@property (weak, nonatomic) IBOutlet UISwitch *navigateToSafeDistanceSwitch;

@end

@implementation MiniDroneVC

-(void)viewDidLoad {
    [super viewDidLoad];
    _stateSem = dispatch_semaphore_create(0);
    
    _miniDrone = [[MiniDrone alloc] initWithService:_service];
    [_miniDrone setDelegate:self];
    [_miniDrone connect];
    
    UIToolbar *toolbar = [[UIToolbar alloc] init];
    [toolbar sizeToFit];
    
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *doneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self.stickyTimeTextField action:@selector(resignFirstResponder)];
    
    toolbar.items = @[flex, doneButton];
    self.stickyTimeTextField.inputAccessoryView = toolbar;
    
    _connectionAlertView = [[UIAlertView alloc] initWithTitle:[_service name] message:@"Connecting ..."
                                           delegate:self cancelButtonTitle:nil otherButtonTitles:nil, nil];
    self.session = [[AVCaptureSession alloc] init];
    self.rearCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
    if (self.rearCamera != nil) {
        [self.rearCamera lockForConfiguration:nil];
        [self.rearCamera setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
        [self.rearCamera unlockForConfiguration];
        
        self.rearCameraInput = [AVCaptureDeviceInput deviceInputWithDevice:self.rearCamera error:nil];
        if (self.rearCameraInput != nil) {
            if ([self.session canAddInput:self.rearCameraInput]) {
                [self.session addInput:self.rearCameraInput];
            }
        }
    }
    
    if (self.session != nil) {
        self.videoPreviewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
        [self.videoPreviewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
        [self.videoPreviewLayer.connection setVideoOrientation:AVCaptureVideoOrientationLandscapeLeft];
        [self.cameraView.layer insertSublayer:self.videoPreviewLayer atIndex:0];
        [self.videoPreviewLayer setFrame:self.view.frame];
    }
    
    self.videoPreviewOutput = [[AVCaptureVideoDataOutput alloc] init];
    dispatch_queue_t queue = dispatch_queue_create("imagebuffer", nil);
    [self.videoPreviewOutput setSampleBufferDelegate:self queue:queue];
    
    if ([self.session canAddOutput:self.videoPreviewOutput]) {
        [self.session addOutput:self.videoPreviewOutput];
    }
    
    [self.session startRunning];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if ([_miniDrone connectionState] != ARCONTROLLER_DEVICE_STATE_RUNNING) {
        //[_connectionAlertView show];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    if ([self.videoPreviewLayer.connection isVideoOrientationSupported]) {
        switch ([[UIApplication sharedApplication] statusBarOrientation]) {
            case UIInterfaceOrientationLandscapeRight:
                [self.videoPreviewLayer.connection setVideoOrientation:AVCaptureVideoOrientationLandscapeLeft];
                break;
            case UIInterfaceOrientationLandscapeLeft:
                [self.videoPreviewLayer.connection setVideoOrientation:AVCaptureVideoOrientationLandscapeRight];
                break;
            default:
                [self.videoPreviewLayer.connection setVideoOrientation:AVCaptureVideoOrientationLandscapeLeft];
                break;
        }
    }
}

- (void) viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (_connectionAlertView && !_connectionAlertView.isHidden) {
        [_connectionAlertView dismissWithClickedButtonIndex:0 animated:NO];
    }
    _connectionAlertView = [[UIAlertView alloc] initWithTitle:[_service name] message:@"Disconnecting ..."
                                           delegate:self cancelButtonTitle:nil otherButtonTitles:nil, nil];
    [_connectionAlertView show];
    
    // in background, disconnect from the drone
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [_miniDrone disconnect];
        // wait for the disconnection to appear
        dispatch_semaphore_wait(_stateSem, DISPATCH_TIME_FOREVER);
        _miniDrone = nil;
        
        // dismiss the alert view in main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [_connectionAlertView dismissWithClickedButtonIndex:0 animated:YES];
        });
    });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CVImageBufferRef buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CIImage *ciImage = [[CIImage alloc] initWithCVImageBuffer:buffer];
    [self detectFace:ciImage];
//    CGImageRef cgImage = [[CIContext context] createCGImage:ciImage fromRect:ciImage.extent];
//    UIImage *image = [[UIImage alloc] initWithCGImage:cgImage];
//    [self didOutputImage:image];
//    CGImageRelease(cgImage);
}


- (void)detectFace:(CIImage*)image{
    //create req
    if (@available(iOS 11.0, *)) {
        VNDetectFaceRectanglesRequest *faceDetectionReq = [VNDetectFaceRectanglesRequest new];
        VNDetectRectanglesRequest *rectDetectionReq = [VNDetectRectanglesRequest new];
        rectDetectionReq.minimumConfidence = 0.2;
        NSDictionary *d = [[NSDictionary alloc] init];
        //req handler
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:image options:d];
        //send req to handler
        [handler performRequests:@[faceDetectionReq, rectDetectionReq] error:nil];
        
        //is there a face?
        for(VNFaceObservation *observation in faceDetectionReq.results){
            if(observation){
                NSLog(@"face detected!");
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            for (CAShapeLayer *layer in self.cameraView.layer.sublayers) {
                if ([layer isKindOfClass:[CAShapeLayer class]] && layer.strokeColor == [[UIColor blueColor] CGColor]) {
                    [layer removeFromSuperlayer];
                }
            }
            
            for (VNRectangleObservation *observation in rectDetectionReq.results) {
                if (observation) {
                    NSArray *points = @[[NSValue valueWithCGPoint:observation.topLeft], [NSValue valueWithCGPoint:observation.topRight], [NSValue valueWithCGPoint:observation.bottomRight], [NSValue valueWithCGPoint:observation.bottomLeft]];
                    NSArray *convertedPoints = [self convertedPointsFromCamera:points];
                    CAShapeLayer *layer = [self drawPolygon:convertedPoints withColor:[UIColor blueColor]];
                    [self.cameraView.layer addSublayer:layer];
                    //NSLog(@"Average color: %@", [self averageColorForImage:image inArea:layer.frame]);
                    //NSLog(@"Rectangle detected!");
                }
            }
        });
    }
}

- (NSArray *)convertedPointsFromCamera:(NSArray *)points {
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    NSMutableArray *convertedPoints = [NSMutableArray new];
    switch (orientation) {
        case UIDeviceOrientationLandscapeRight:
            for (NSValue *pointValue in points) {
                CGPoint point = [pointValue CGPointValue];
                [convertedPoints addObject:[NSValue valueWithCGPoint: CGPointMake((1 - point.x) * self.view.frame.size.width, point.y * self.view.frame.size.height)]];
            }
            return convertedPoints;
        case UIDeviceOrientationLandscapeLeft:
            for (NSValue *pointValue in points) {
                CGPoint point = [pointValue CGPointValue];
                [convertedPoints addObject:[NSValue valueWithCGPoint: CGPointMake(point.x * self.view.frame.size.width, (1 - point.y) * self.view.frame.size.height)]];
            }
            return convertedPoints;
        default:
            return @[];
    }
}

- (CAShapeLayer *)drawPolygon:(NSArray<NSValue *> *)points withColor:(UIColor *)color {
    CAShapeLayer *layer = [CAShapeLayer new];
    layer.fillColor = [[UIColor colorWithRed:0.0 / 255.0 green:0.0 / 255.0 blue:255.0 / 255.0 alpha:0.15] CGColor];
    layer.strokeColor = color.CGColor;
    layer.lineWidth = 2;
    UIBezierPath *path = [UIBezierPath new];
    if (points.count == 4) {
        NSArray *xs = @[[NSNumber numberWithInteger:[points[0] CGPointValue].x], [NSNumber numberWithInteger:[points[1] CGPointValue].x], [NSNumber numberWithInteger:[points[2] CGPointValue].x], [NSNumber numberWithInteger:[points[3] CGPointValue].x]];
        NSArray *ys = @[[NSNumber numberWithInteger:[points[0] CGPointValue].y], [NSNumber numberWithInteger:[points[1] CGPointValue].y], [NSNumber numberWithInteger:[points[2] CGPointValue].y], [NSNumber numberWithInteger:[points[3] CGPointValue].y]];
        
        NSNumber *minX = [xs valueForKeyPath:@"@min.self"];
        NSNumber *minY = [ys valueForKeyPath:@"@min.self"];
        
        NSNumber *maxX = [xs valueForKeyPath:@"@max.self"];
        NSNumber *maxY = [ys valueForKeyPath:@"@max.self"];
        
        NSNumber *midX = [NSNumber numberWithInt:([minX intValue] + [maxX intValue]) / 2];
        NSNumber *midY = [NSNumber numberWithInt:([minY intValue] + [maxY intValue]) / 2];
        
        CGPoint polyCenter = CGPointMake(midX.floatValue, midY.floatValue);
        
        [self determinePositionWith:polyCenter];
        
        CGSize rectSize = CGSizeMake([maxX floatValue] - [minX floatValue], [maxY floatValue] - [minY floatValue]);
        NSLog(@"rect: %@", NSStringFromCGSize(rectSize));
        
//        [self determineDepthWith:rectSize];
//        NSLog(@"Centerpoint: %@", NSStringFromCGPoint(polyCenter));
//        NSLog(@"\nminX: %@\nmaxX: %@\nminY: %@\nmaxY: %@", minX, maxX, minY, maxY);
    }
    [path moveToPoint:[[points lastObject] CGPointValue]];
    for (NSValue *val in points) {
        [path addLineToPoint:[val CGPointValue]];
    }
    [layer setPath:path.CGPath];
    return layer;
}

- (void)determinePositionWith:(CGPoint)point {
    CGFloat xOffset = point.x - CGRectGetMidX(self.cameraView.layer.frame);
    CGFloat yOffset = point.y - CGRectGetMidY(self.cameraView.layer.frame);
    
    if (xOffset < -40 && yOffset < -40) {
        self.directionLabel.text = @"Top Left";
        [self handleLocation:TopLeft];
    } else if (xOffset < -40 && yOffset > -40 && yOffset < 40) {
        self.directionLabel.text = @"Left";
        [self handleLocation:Left];
    } else if (xOffset < -40 && yOffset > 40) {
        self.directionLabel.text = @"Bottom Left";
        [self handleLocation:BottomLeft];
    } else if (xOffset > -40 && xOffset < 40 && yOffset < -40) {
        self.directionLabel.text = @"Top";
        [self handleLocation:Top];
    } else if (xOffset > -40 && xOffset < 40 && yOffset > 40) {
        self.directionLabel.text = @"Bottom";
        [self handleLocation:Bottom];
    } else if (xOffset > 40 && yOffset < -40) {
        self.directionLabel.text = @"Top Right";
        [self handleLocation:TopRight];
    } else if (xOffset > 40 && yOffset > -40 && yOffset < 40) {
        self.directionLabel.text = @"Right";
        [self handleLocation:Right];
    } else if (xOffset > 40 && yOffset > 40) {
        self.directionLabel.text = @"Bottom Right";
        [self handleLocation:BottomRight];
    } else {
        self.directionLabel.text = @"Center";
        [self handleLocation:Center];
    }
    //NSLog(@"\nxOffset: %f\nyOffset: %f", xOffset, yOffset);
    //NSLog(@"Cameraview centerX: %f\nCameraview centerY: %f", CGRectGetMidX(self.cameraView.layer.frame), CGRectGetMidY(self.cameraView.layer.frame));
}

- (void)determineDepthWith:(CGSize)size {
    CGFloat maxSide = MAX(size.width, size.height);
    if ((maxSide + 50) < 250) {
        self.distanceLabel.text = @"Far";
        [self handleDepth:Far];
    } else if ((maxSide - 50) > 250) {
        self.distanceLabel.text = @"Close";
        [self handleDepth:Close];
    } else {
        self.distanceLabel.text = @"Acceptable";
        [self handleDepth:Acceptable];
    }
}

- (IBAction)navigationToCenterSwitchChanged:(id)sender {
    [self stopDrone];
}

- (IBAction)navigateToSafeDistanceSwitchChanged:(id)sender {
    [self stopDrone];
}

- (void)handleDepth:(ObservationDistance)distance {
    return;
    if (self.observationDistance == distance || !self.navigateToSafeDistanceSwitch.isOn) return;
    self.observationDistance = distance;
    NSLog(@"\nhandleDistance: %u", distance);
    [_miniDrone setFlag:1];
    switch (distance) {
        case Far:
            [_miniDrone setPitch:20];
            break;
        case Acceptable:
            [_miniDrone setPitch:0];
            break;
        case Close:
            [_miniDrone setPitch:-20];
            break;
        default:
            break;
    }
}

- (void)handleLocation:(ObservationLocation)location {
    if (self.observationLocation == location || !self.navigateToCenterSwitch.isOn) return;
    self.observationLocation = location;
    NSLog(@"\nhandleLocation: %u", location);
    [_miniDrone setFlag:1];
    switch (location) {
        case TopLeft:
            [_miniDrone setRoll:-20];
            [_miniDrone setGaz:-20];
            break;
        case Left:
            [_miniDrone setRoll:-20];
            [_miniDrone setGaz:0];
            break;
        case BottomLeft:
            [_miniDrone setRoll:-20];
            [_miniDrone setGaz:20];
            break;
        case Top:
            [_miniDrone setRoll:0];
            [_miniDrone setGaz:-20];
            break;
        case Center:
            [_miniDrone setRoll:0];
            [_miniDrone setGaz:0];
            break;
        case Bottom:
            [_miniDrone setRoll:-20];
            [_miniDrone setGaz:-20];
            break;
        case TopRight:
            [_miniDrone setRoll:20];
            [_miniDrone setGaz:-20];
            break;
        case Right:
            [_miniDrone setRoll:20];
            [_miniDrone setGaz:0];
            break;
        case BottomRight:
            [_miniDrone setRoll:20];
            [_miniDrone setGaz:20];
            break;
        default:
            break;
    }
}

- (UIColor *)averageColorForImage:(CIImage *)ciImage inArea:(CGRect)area {
    CIVector *extentVector = [CIVector vectorWithX:ciImage.extent.origin.x Y:ciImage.extent.origin.y Z:ciImage.extent.size.width W:ciImage.extent.size.height];
    CIFilter *extentFilter = [CIFilter filterWithName:@"CIAreaAverage" withInputParameters:@{kCIInputImageKey: ciImage, kCIInputExtentKey: extentVector}];
    CIImage *outputImage = [extentFilter outputImage];
    if (outputImage) {
        const void *bitmap;
        CIContext *context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: [NSNull null]}];
        [context render:outputImage toBitmap:&bitmap rowBytes:4 bounds:ciImage.extent format:kCIFormatRGBA8 colorSpace:nil];
        //NSLog(@"%@", [NSValue valueWithPointer:bitmap]);
        //NSLog(@"bitmap: %@", *bitmap);
        return nil;//[UIColor colorWithRed:(CGFloat)((int)bitmap[0] / 255) green:(CGFloat)((int)bitmap[1] / 255) blue:(CGFloat)((int)bitmap[2] / 255) alpha:(CGFloat)((int)bitmap[3] / 255)];
    } else {
        return nil;
    }
}


#pragma mark MiniDroneDelegate
-(void)miniDrone:(MiniDrone *)miniDrone connectionDidChange:(eARCONTROLLER_DEVICE_STATE)state {
    switch (state) {
        case ARCONTROLLER_DEVICE_STATE_RUNNING:
            [_connectionAlertView dismissWithClickedButtonIndex:0 animated:YES];
            break;
        case ARCONTROLLER_DEVICE_STATE_STOPPED:
            dispatch_semaphore_signal(_stateSem);
            
            // Go back
            [self.navigationController popViewControllerAnimated:YES];
            break;
            
        default:
            break;
    }
}

- (void)miniDrone:(MiniDrone*)miniDrone batteryDidChange:(int)batteryPercentage {
    [_batteryLabel setText:[NSString stringWithFormat:@"%d%%", batteryPercentage]];
}

- (void)miniDrone:(MiniDrone*)miniDrone flyingStateDidChange:(eARCOMMANDS_MINIDRONE_PILOTINGSTATE_FLYINGSTATECHANGED_STATE)state {
    switch (state) {
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_LANDED:
            [_takeOffLandBt setTitle:@"Take off" forState:UIControlStateNormal];
            [_takeOffLandBt setEnabled:YES];
            [_downloadMediasBt setEnabled:YES];
            break;
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_FLYING:
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_HOVERING:
            [_takeOffLandBt setTitle:@"Land" forState:UIControlStateNormal];
            [_takeOffLandBt setEnabled:YES];
            [_downloadMediasBt setEnabled:NO];
            break;
        default:
            [_takeOffLandBt setEnabled:NO];
            [_downloadMediasBt setEnabled:NO];
    }
}

- (BOOL)miniDrone:(MiniDrone*)bebopDrone configureDecoder:(ARCONTROLLER_Stream_Codec_t)codec {
    
    return [_videoView configureDecoder:codec];
}

- (BOOL)miniDrone:(MiniDrone*)bebopDrone didReceiveFrame:(ARCONTROLLER_Frame_t*)frame {
    NSData *data = [NSData dataWithBytes:frame->data length:sizeof(frame->data)];
    UIImage *image = [UIImage imageWithData:data];
    return [_videoView displayFrame:frame];
}

- (void)miniDrone:(MiniDrone*)miniDrone didFoundMatchingMedias:(NSUInteger)nbMedias {
    _nbMaxDownload = nbMedias;
    _currentDownloadIndex = 1;
    
    if (nbMedias > 0) {
        [_downloadAlertController setMessage:@"Downloading medias"];
        UIViewController *customVC = [[UIViewController alloc] init];
        _downloadProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        [_downloadProgressView setProgress:0];
        [customVC.view addSubview:_downloadProgressView];
        
        [customVC.view addConstraint:[NSLayoutConstraint
                                      constraintWithItem:_downloadProgressView
                                      attribute:NSLayoutAttributeCenterX
                                      relatedBy:NSLayoutRelationEqual
                                      toItem:customVC.view
                                      attribute:NSLayoutAttributeCenterX
                                      multiplier:1.0f
                                      constant:0.0f]];
        [customVC.view addConstraint:[NSLayoutConstraint
                                      constraintWithItem:_downloadProgressView
                                      attribute:NSLayoutAttributeBottom
                                      relatedBy:NSLayoutRelationEqual
                                      toItem:customVC.bottomLayoutGuide
                                      attribute:NSLayoutAttributeTop
                                      multiplier:1.0f
                                      constant:-20.0f]];
        
        [_downloadAlertController setValue:customVC forKey:@"contentViewController"];
    } else {
        [_downloadAlertController dismissViewControllerAnimated:YES completion:^{
            _downloadProgressView = nil;
            _downloadAlertController = nil;
        }];
    }
}

- (void)miniDrone:(MiniDrone*)miniDrone media:(NSString*)mediaName downloadDidProgress:(int)progress {
    float completedProgress = ((_currentDownloadIndex - 1) / (float)_nbMaxDownload);
    float currentProgress = (progress / 100.f) / (float)_nbMaxDownload;
    [_downloadProgressView setProgress:(completedProgress + currentProgress)];
}

- (void)miniDrone:(MiniDrone*)miniDrone mediaDownloadDidFinish:(NSString*)mediaName {
    _currentDownloadIndex++;
    
    if (_currentDownloadIndex > _nbMaxDownload) {
        [_downloadAlertController dismissViewControllerAnimated:YES completion:^{
            _downloadProgressView = nil;
            _downloadAlertController = nil;
        }];
        
    }
}

#pragma mark buttons click
- (IBAction)emergencyClicked:(id)sender {
    [_miniDrone emergency];
}

- (IBAction)takeOffLandClicked:(id)sender {
    switch ([_miniDrone flyingState]) {
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_LANDED:
            [_miniDrone takeOff];
            [_takeOffLandBt setImage:[UIImage imageNamed:@"landing"] forState:UIControlStateNormal];
            break;
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_FLYING:
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_HOVERING:
            [_miniDrone land];
            [_takeOffLandBt setImage:[UIImage imageNamed:@"takeoff"] forState:UIControlStateNormal];
            break;
        default:
            break;
    }
}

- (IBAction)takePictureClicked:(id)sender {
    [_miniDrone takePicture];
}

- (IBAction)downloadMediasClicked:(id)sender {
    [_downloadAlertController dismissViewControllerAnimated:YES completion:nil];
    
    _downloadAlertController = [UIAlertController alertControllerWithTitle:@"Download"
                                                                   message:@"Fetching medias"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                                         handler:^(UIAlertAction * action) {
                                                             [_miniDrone cancelDownloadMedias];
                                                         }];
    [_downloadAlertController addAction:cancelAction];
    
    
    UIViewController *customVC = [[UIViewController alloc] init];
    UIActivityIndicatorView* spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [spinner startAnimating];
    [customVC.view addSubview:spinner];
    
    [customVC.view addConstraint:[NSLayoutConstraint
                                  constraintWithItem: spinner
                                  attribute:NSLayoutAttributeCenterX
                                  relatedBy:NSLayoutRelationEqual
                                  toItem:customVC.view
                                  attribute:NSLayoutAttributeCenterX
                                  multiplier:1.0f
                                  constant:0.0f]];
    [customVC.view addConstraint:[NSLayoutConstraint
                                  constraintWithItem:spinner
                                  attribute:NSLayoutAttributeBottom
                                  relatedBy:NSLayoutRelationEqual
                                  toItem:customVC.bottomLayoutGuide
                                  attribute:NSLayoutAttributeTop
                                  multiplier:1.0f
                                  constant:-20.0f]];
    
    
    [_downloadAlertController setValue:customVC forKey:@"contentViewController"];
    
    [self presentViewController:_downloadAlertController animated:YES completion:nil];
    
    [_miniDrone downloadMedias];
}

- (IBAction)powerSliderValueChanged:(id)sender {
    self.powerLabel.text = [NSString stringWithFormat:@"%g", roundf(self.powerSlider.value)];
}

- (void)stopDrone {
    [_miniDrone setFlag:0];
    [_miniDrone setGaz:0];
    [_miniDrone setYaw:0];
    [_miniDrone setPitch:0];
}

- (IBAction)gazUpTouchDown:(id)sender {
    [_miniDrone setGaz:roundf(self.powerSlider.value)];
    if (![self.stickyTimeTextField.text isEqualToString:@""]) {
        double delay = [self.stickyTimeTextField.text doubleValue];
        [self performSelector:@selector(stopDrone) withObject:nil afterDelay:delay / 1000];
    }
}

- (IBAction)gazDownTouchDown:(id)sender {
    [_miniDrone setGaz:-roundf(self.powerSlider.value)];
    if (![self.stickyTimeTextField.text isEqualToString:@""]) {
        double delay = [self.stickyTimeTextField.text doubleValue];
        [self performSelector:@selector(stopDrone) withObject:nil afterDelay:delay / 1000];
    }
}

- (IBAction)gazUpTouchUp:(id)sender {
    if (![self.stickyTimeTextField.text isEqualToString:@""]) return;
    [_miniDrone setGaz:0];
}

- (IBAction)gazDownTouchUp:(id)sender {
    if (![self.stickyTimeTextField.text isEqualToString:@""]) return;
    [_miniDrone setGaz:0];
}

- (IBAction)yawLeftTouchDown:(id)sender {
    [_miniDrone setYaw:-roundf(self.powerSlider.value)];
    if (![self.stickyTimeTextField.text isEqualToString:@""]) {
        double delay = [self.stickyTimeTextField.text doubleValue];
        [self performSelector:@selector(stopDrone) withObject:nil afterDelay:delay / 1000];
    }
}

- (IBAction)yawRightTouchDown:(id)sender {
    [_miniDrone setYaw:roundf(self.powerSlider.value)];
    if (![self.stickyTimeTextField.text isEqualToString:@""]) {
        double delay = [self.stickyTimeTextField.text doubleValue];
        [self performSelector:@selector(stopDrone) withObject:nil afterDelay:delay / 1000];
    }
}

- (IBAction)yawLeftTouchUp:(id)sender {
    if (![self.stickyTimeTextField.text isEqualToString:@""]) return;
    [_miniDrone setYaw:0];
}

- (IBAction)yawRightTouchUp:(id)sender {
    if (![self.stickyTimeTextField.text isEqualToString:@""]) return;
    [_miniDrone setYaw:0];
}

- (IBAction)rollLeftTouchDown:(id)sender {
    [_miniDrone setFlag:1];
    [_miniDrone setRoll:-roundf(self.powerSlider.value)];
    if (![self.stickyTimeTextField.text isEqualToString:@""]) {
        double delay = [self.stickyTimeTextField.text doubleValue];
        [self performSelector:@selector(stopDrone) withObject:nil afterDelay:delay / 1000];
    }
}

- (IBAction)rollRightTouchDown:(id)sender {
    [_miniDrone setFlag:1];
    [_miniDrone setRoll:roundf(self.powerSlider.value)];
    if (![self.stickyTimeTextField.text isEqualToString:@""]) {
        double delay = [self.stickyTimeTextField.text doubleValue];
        [self performSelector:@selector(stopDrone) withObject:nil afterDelay:delay / 1000];
    }
}

- (IBAction)rollLeftTouchUp:(id)sender {
    if (![self.stickyTimeTextField.text isEqualToString:@""]) return;
    [_miniDrone setFlag:0];
    [_miniDrone setRoll:0];
}

- (IBAction)rollRightTouchUp:(id)sender {
    if (![self.stickyTimeTextField.text isEqualToString:@""]) return;
    [_miniDrone setFlag:0];
    [_miniDrone setRoll:0];
}

- (IBAction)pitchForwardTouchDown:(id)sender {
    [_miniDrone setFlag:1];
    [_miniDrone setPitch:roundf(self.powerSlider.value)];
    if (![self.stickyTimeTextField.text isEqualToString:@""]) {
        double delay = [self.stickyTimeTextField.text doubleValue];
        [self performSelector:@selector(stopDrone) withObject:nil afterDelay:delay / 1000];
    }
}

- (IBAction)pitchBackTouchDown:(id)sender {
    [_miniDrone setFlag:1];
    [_miniDrone setPitch:-roundf(self.powerSlider.value)];
    if (![self.stickyTimeTextField.text isEqualToString:@""]) {
        double delay = [self.stickyTimeTextField.text doubleValue];
        [self performSelector:@selector(stopDrone) withObject:nil afterDelay:delay / 1000];
    }
}

- (IBAction)pitchForwardTouchUp:(id)sender {
    if (![self.stickyTimeTextField.text isEqualToString:@""]) return;
    [_miniDrone setFlag:0];
    [_miniDrone setPitch:0];
}

- (IBAction)pitchBackTouchUp:(id)sender {
    if (![self.stickyTimeTextField.text isEqualToString:@""]) return;
    [_miniDrone setFlag:0];
    [_miniDrone setPitch:0];
}

@end

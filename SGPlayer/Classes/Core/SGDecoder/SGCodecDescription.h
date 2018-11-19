//
//  SGCodecDescription.h
//  SGPlayer
//
//  Created by Single on 2018/11/15.
//  Copyright © 2018 single. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SGTimeLayout.h"
#import "SGTrack.h"
#import "avcodec.h"

@interface SGCodecDescription : NSObject <NSCopying>

@property (nonatomic) SGTrack * track;
@property (nonatomic) AVRational timebase;
@property (nonatomic) CMTimeRange timeRange;
@property (nonatomic) AVCodecParameters * codecpar;
@property (nonatomic, copy) NSArray <SGTimeLayout *> * timeLayouts;

- (BOOL)isEqualToDescription:(SGCodecDescription *)codecpar;

- (void)appendTimeLayout:(SGTimeLayout *)timeLayout;
- (void)appendTimeRange:(CMTimeRange)timeRange;
- (CMTimeRange)layoutTimeRange;

@end

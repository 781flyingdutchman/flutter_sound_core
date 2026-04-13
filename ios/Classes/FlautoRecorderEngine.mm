//
//  AudioRecorder.m
//  flutter_sound
//
//  Created by larpoux on 02/05/2020.
//
/*
 * Copyright 2018, 2019, 2020, 2021 Dooboolab.
 *
 * This file is part of Flutter-Sound.
 *
 * Flutter-Sound is free software: you can redistribute it and/or modify
 * it under the terms of the Mozilla Public License version 2 (MPL2.0),
 * as published by the Mozilla organization.
 *
 * Flutter-Sound is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * MPL General Public License for more details.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */



#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#import "Flauto.h"
#import "FlautoRecorderEngine.h"


//-------------------------------------------------------------------------------------------------------------------------------------------



/* ctor */ AudioRecorderEngine::AudioRecorderEngine(t_CODEC coder, NSString* path, NSMutableDictionary* audioSettings, long bufferSize, bool enableVoiceProcessing, FlautoRecorder* owner )
{
 
         flautoRecorder = owner;
         engine = [[AVAudioEngine alloc] init];
         dateCumul = 0;
         previousTS = 0;
         status = 0;
        
   
        
        // On macOS Catalyst (iOS app on Mac / "Made for iPad" mode), the AVAudioEngine's
        // inputNode reports 0 channels unless the AVAudioSession is explicitly activated
        // at the native level before we query the format. Without this, the tap produces
        // silence / zero-byte callbacks even though bytes appear to flow at the Dart level.
        NSError* sessionError = nil;
        [[AVAudioSession sharedInstance] setCategory: AVAudioSessionCategoryPlayAndRecord
                                         withOptions: AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                                               error: &sessionError];
        if (sessionError) {
            NSLog(@"[FlautoRecorderEngine] AVAudioSession setCategory error: %@", sessionError);
        }
        [[AVAudioSession sharedInstance] setActive: YES error: &sessionError];
        if (sessionError) {
            NSLog(@"[FlautoRecorderEngine] AVAudioSession setActive error: %@", sessionError);
        }

        AVAudioInputNode* inputNode = [engine inputNode];
        AVAudioFormat* inputFormat = [inputNode outputFormatForBus: 0];
        NSLog(@"[FlautoRecorderEngine] inputNode format: ch=%u sr=%.0f", (unsigned)[inputFormat channelCount], [inputFormat sampleRate]);
        int outputChannelCount = [audioSettings [AVNumberOfChannelsKey]  intValue];
        NSNumber* sampleRate = audioSettings [AVSampleRateKey];
        bool interleaved = ![audioSettings [AVLinearPCMIsNonInterleaved] boolValue];

        NSFileManager* fileManager = [NSFileManager defaultManager];
        NSURL* fileURL = nil;
        if (path != nil && path != (id)[NSNull null])
        {
                [fileManager removeItemAtPath:path error:nil];
                [fileManager createFileAtPath: path contents:nil attributes:nil];
                fileURL = [[NSURL alloc] initFileURLWithPath: path];
                fileHandle = [NSFileHandle fileHandleForWritingAtPath: path];
        } else
        {
                fileHandle = nil;
        }

     
    
         AVAudioCommonFormat commonFormat = (coder == pcmFloat32) ?  AVAudioPCMFormatFloat32 : AVAudioPCMFormatInt16;

         AVAudioFormat* recordingFormat = [[AVAudioFormat alloc] initWithCommonFormat: commonFormat sampleRate: sampleRate.doubleValue channels: outputChannelCount interleaved: interleaved];
         AVAudioConverter* converter = [[AVAudioConverter alloc]initFromFormat: inputFormat toFormat: recordingFormat];
         //AVAudioFormat *format = [inputNode outputFormatForBus: 0];

 
         [inputNode installTapOnBus: 0 bufferSize: (int)bufferSize format: nil block:
         ^(AVAudioPCMBuffer* _Nonnull buffer, AVAudioTime* _Nonnull when)
         {
             @autoreleasepool {
                         inputStatus = AVAudioConverterInputStatus_HaveData ;
                         
                         double ratio = recordingFormat.sampleRate / inputFormat.sampleRate;
                         AVAudioFrameCount requiredCapacity = (AVAudioFrameCount)((double)[buffer frameCapacity] * ratio) + 1024;
                         
                         AVAudioPCMBuffer* convertedBuffer = [[AVAudioPCMBuffer alloc]initWithPCMFormat: recordingFormat frameCapacity: requiredCapacity];
                                                  
                         AVAudioConverterInputBlock inputBlock =
                         ^AVAudioBuffer*(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus *outStatus)
                         {
                                 *outStatus = inputStatus;
                                 inputStatus =  AVAudioConverterInputStatus_NoDataNow;
                                 return buffer;
                         };
                         NSError* error;
                         AVAudioConverterOutputStatus r = [converter convertToBuffer: convertedBuffer error: &error withInputFromBlock: inputBlock];
                         if (r == AVAudioConverterOutputStatus_Error)
                         {
                         }
            
                         NSUInteger stride = [convertedBuffer stride]; // Should be 1 or 2 depending of the number of channels if interleaved. Should be 1 if not interleaved
                         int frameLength = [convertedBuffer frameLength];
                         if (frameLength > 0)
                         {
                                 if (interleaved)
                                 {
                                     NSData* data;
                                     if (coder == pcmFloat32)
                                     {
                                         float *const  bb = [convertedBuffer floatChannelData][0];
                                         this ->computePeakLevelForFloat32Blk(bb, frameLength * outputChannelCount);
                                         data = [[NSData alloc] initWithBytes: bb length: frameLength * 4 * outputChannelCount];
                                     } else
                                     if (coder == pcm16)
                                     {
                                         int16_t *const  bb = [convertedBuffer int16ChannelData][0];
                                         this ->computePeakLevelForInt16Blk(bb, frameLength * outputChannelCount);
                                         data = [[NSData alloc] initWithBytes: bb length: frameLength * 2 * outputChannelCount];
                                     } else
                                     {
                                         [NSException raise: @"Invalid codec" format:@"codec == %d is invalid", coder];
                                     }
                                     
                                     if (fileHandle != nil)
                                     {
                                         [fileHandle writeData: data];
                                     } else // Stream
                                     {
                                         dispatch_async(dispatch_get_main_queue(),
                                        ^{
                                            @autoreleasepool {
                                                 if (flautoRecorder == nil || status == 0) // something bad in the recorder : skip the callback
                                                 {
                                                     return;
                                                 }
                                                 [flautoRecorder  recordingData: data];
                                            }
                                         });
                                     }
                                     
                                 } else // Not interleaved
                                 {
                                     assert (stride == 1);
                                     NSMutableArray* recdata = [NSMutableArray arrayWithCapacity: outputChannelCount];
                                     for (int channel = 0; channel < outputChannelCount; ++channel)
                                     {
                                         NSData* data;
                                         if (coder == pcmFloat32)
                                         {
                                             float* const  bb = [convertedBuffer floatChannelData][channel];
                                             this ->computePeakLevelForFloat32Blk(bb, frameLength );
                                             data = [[NSData alloc] initWithBytes: bb length: frameLength * 4];
                                         } else
                                         if (coder == pcm16)
                                         {
                                             int16_t *const  bb = [convertedBuffer int16ChannelData][channel];
                                             this ->computePeakLevelForInt16Blk(bb, frameLength );
                                             data = [[NSData alloc] initWithBytes: bb length: frameLength * 2];
                                         } else
                                         {
                                             [NSException raise: @"Invalid codec" format:@"codec == %d is invalid", coder];
                                         }
                                         [recdata addObject: data];
                                     }
                                     dispatch_async(dispatch_get_main_queue(),
                                    ^{
                                        @autoreleasepool {
                                             if (flautoRecorder == nil || getStatus() == 0) // something bad
                                             {
                                                 return;
                                             }
                                             if (coder == pcmFloat32)
                                             {
                                                 [flautoRecorder  recordingDataFloat32: recdata];
                                             } else
                                             if (coder == pcm16)
                                             {
                                                 [flautoRecorder  recordingDataInt16: recdata];
                                             }
                                        }
                                     });
                              } // Not interleaved
                         } // (frameLength > 0)
             }
         }];
     
}


void AudioRecorderEngine::computePeakLevelForFloat32Blk(float* pt, int ln)
{
    float m = 0.0;
    for (int i = 0; i < ln; ++pt, ++i)
    {
            float curSample = abs(*pt);
        
            if (curSample > 1.0 || curSample < -1.0)
            {
                curSample = 0;
            }
            if ( curSample > m )
            {
                m = curSample;
            }
        
        
    }
    m *= 0x7FFF;
    if ( m > maxAmplitude )
    {
        maxAmplitude = m;
    }
    ++ nbrSamples;
}


void AudioRecorderEngine::computePeakLevelForInt16Blk(int16_t* pt, int ln)
{
    for (int i = 0; i < ln ; ++pt, ++i)
    {
        int curSample = abs(*pt);
        if ( curSample > maxAmplitude )
        {
            maxAmplitude = curSample;
        }
        
    }
    ++ nbrSamples;
}


int AudioRecorderEngine::startRecorder()
{
        [engine startAndReturnError: nil];
        previousTS = CACurrentMediaTime() * 1000;
        status = 2;
        return status;
}

void AudioRecorderEngine::stopRecorder()
{
        [engine stop];
        [fileHandle closeFile];
        if (previousTS != 0)
        {
                dateCumul += CACurrentMediaTime() * 1000 - previousTS;
                previousTS = 0;
        }
        status = 0;
        engine = nil;
}

void AudioRecorderEngine::resumeRecorder()
{
        [engine startAndReturnError: nil];
        previousTS = CACurrentMediaTime() * 1000;
        status = 2;
 
}

void AudioRecorderEngine::pauseRecorder()
{
        [engine pause];
        if (previousTS != 0)
        {
                dateCumul += CACurrentMediaTime() * 1000 - previousTS;
                previousTS = 0;
        }
        status = 1;
 
}

NSNumber* AudioRecorderEngine::recorderProgress()
{
        long r = dateCumul;
        if (previousTS != 0)
        {
                r += CACurrentMediaTime() * 1000 - previousTS;
        }
        return [NSNumber numberWithInt: (int)r];
}

NSNumber* AudioRecorderEngine::dbPeakProgress()
{
        
        if (nbrSamples > 0)
        {
            previousAmplitude = maxAmplitude;
            maxAmplitude = 0;
            nbrSamples = 0;
        }
        double max = previousAmplitude;
        if (max == 0.0)
        {
                // if the microphone is off we get 0 for the amplitude which causes
                // db to be infinite.
                return [NSNumber numberWithDouble: 0.0];
        }

        // Calculate db based on the following article.
        // https://stackoverflow.com/questions/10655703/what-does-androids-getmaxamplitude-function-for-the-mediarecorder-actually-gi
        //
        double ref_pressure = 51805.5336;
        double p = max / ref_pressure;
        double p0 = 0.0002;
        double l = log10(p / p0);

        double db = 20.0 * l;

        return [NSNumber numberWithDouble: db];
}


int AudioRecorderEngine::getStatus()
{
     return status;
}



//-----------------------------------------------------------------------------------------------------------------------------------------
/* ctor */ avAudioRec::avAudioRec( t_CODEC codec, NSString* path, NSMutableDictionary* audioSettings, FlautoRecorder* owner)
{
        flautoRecorder = owner;
        isPaused = false;

        NSURL *audioFileURL;
        {
                audioFileURL = [NSURL fileURLWithPath: path];
        }

        audioRecorder = [[AVAudioRecorder alloc]
                        initWithURL: audioFileURL
                        settings: audioSettings
                        error:nil];
}

/* dtor */ avAudioRec::~avAudioRec()
{
        [audioRecorder stop];
        isPaused = false;
}

int avAudioRec::startRecorder()
{
          [audioRecorder setDelegate: flautoRecorder];
          [audioRecorder record];
          [audioRecorder setMeteringEnabled: YES];
          isPaused = false;
          if ( [audioRecorder isRecording] )
             return 2;
          return 0;
}

void avAudioRec::stopRecorder()
{
        isPaused = false;
        [audioRecorder stop];
}

void avAudioRec::resumeRecorder()
{
        [audioRecorder record];
        isPaused = false;
}

void avAudioRec::pauseRecorder()
{
        [audioRecorder pause];
        isPaused = true;

}

NSNumber* avAudioRec::recorderProgress()
{
        NSNumber* duration =    [NSNumber numberWithLong: (long)(audioRecorder.currentTime * 1000 )];

        
        [audioRecorder updateMeters];
        return duration;
}

NSNumber* avAudioRec::dbPeakProgress()
{
    float peak = [audioRecorder peakPowerForChannel: 0];
    //float toto = pow(10, (0.05 * peak));
    //float titi = pow(10.0, peak / 20.0) * 160.0;
        NSNumber* normalizedPeakLevel = [NSNumber numberWithDouble: pow(10.0, peak / 20.0) * 160.0];
        return normalizedPeakLevel;

}

int avAudioRec::getStatus()
{
     if ( [audioRecorder isRecording] )
        return 2;
     else if (isPaused)
        return 1;
     return 0;
}



//-----------------------------------------------------------------------------------------------------------------------------------------
// AudioQueuePCMRecorder
// Uses AudioQueueNewInput with raw PCM-16 -- the same HAL path as AVAudioRecorder --
// which works on macOS Catalyst where AVAudioEngine.inputNode tap produces silence.
// Raw PCM bytes are delivered to FlautoRecorder via recordingData: stream callback.
//-----------------------------------------------------------------------------------------------------------------------------------------

static const int kNumBuffers = 3;
static const int kBufferSizeBytes = 3200; // ~100ms at 16kHz mono PCM16

void AudioQueuePCMRecorder::AudioQueueCallback(
        void* userdata,
        AudioQueueRef queue,
        AudioQueueBufferRef buffer,
        const AudioTimeStamp* startTime,
        UInt32 numPackets,
        const AudioStreamPacketDescription* packetDesc)
{
    AudioQueuePCMRecorder* self = (AudioQueuePCMRecorder*)userdata;
    if (self->status != 2) {
        AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
        return;
    }

    NSUInteger byteCount = buffer->mAudioDataByteSize;
    if (byteCount > 0) {
        int16_t* samples = (int16_t*)buffer->mAudioData;
        int sampleCount = (int)(byteCount / 2);
        self->computePeakLevelForInt16Blk(samples, sampleCount);

        NSData* data = [NSData dataWithBytes:buffer->mAudioData length:byteCount];
        if (self->fileHandle != nil) {
            [self->fileHandle writeData:data];
        } else {
            FlautoRecorder* recorder = self->flautoRecorder;
            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    if (recorder == nil || self->status != 2) return;
                    [recorder recordingData:data];
                }
            });
        }
    }
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

void AudioQueuePCMRecorder::computePeakLevelForInt16Blk(int16_t* pt, int ln)
{
    for (int i = 0; i < ln; ++pt, ++i) {
        int cur = abs(*pt);
        if (cur > maxAmplitude) maxAmplitude = cur;
    }
    ++nbrSamples;
}

AudioQueuePCMRecorder::AudioQueuePCMRecorder(NSString* path, double sr, int ch, FlautoRecorder* owner)
{
    flautoRecorder = owner;
    sampleRate = sr;
    numChannels = ch;
    audioQueue = nil;
    dateCumul = 0;
    previousTS = 0;
    status = 0;

    if (path != nil && path != (id)[NSNull null]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    } else {
        fileHandle = nil;
    }

    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mSampleRate       = sr;
    fmt.mChannelsPerFrame = (UInt32)ch;
    fmt.mBitsPerChannel   = 16;
    fmt.mBytesPerFrame    = (UInt32)(2 * ch);
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerPacket   = fmt.mBytesPerFrame;

    OSStatus err = AudioQueueNewInput(&fmt, AudioQueueCallback, this, nil, nil, 0, &audioQueue);
    if (err != noErr) {
        NSLog(@"[AudioQueuePCMRecorder] AudioQueueNewInput failed: %d", (int)err);
        audioQueue = nil;
        return;
    }
    NSLog(@"[AudioQueuePCMRecorder] Created AudioQueue PCM16 %.0fHz %dch", sr, ch);

    for (int i = 0; i < kNumBuffers; i++) {
        AudioQueueBufferRef buf;
        AudioQueueAllocateBuffer(audioQueue, kBufferSizeBytes, &buf);
        AudioQueueEnqueueBuffer(audioQueue, buf, 0, NULL);
    }
}

AudioQueuePCMRecorder::~AudioQueuePCMRecorder()
{
    if (audioQueue != nil) {
        AudioQueueDispose(audioQueue, true);
        audioQueue = nil;
    }
    [fileHandle closeFile];
}

int AudioQueuePCMRecorder::startRecorder()
{
    if (audioQueue == nil) return 0;
    OSStatus err = AudioQueueStart(audioQueue, nil);
    if (err != noErr) {
        NSLog(@"[AudioQueuePCMRecorder] AudioQueueStart failed: %d", (int)err);
        return 0;
    }
    previousTS = (long)(CACurrentMediaTime() * 1000);
    status = 2;
    NSLog(@"[AudioQueuePCMRecorder] Recording started OK");
    return status;
}

void AudioQueuePCMRecorder::stopRecorder()
{
    if (audioQueue != nil) AudioQueueStop(audioQueue, true);
    [fileHandle closeFile];
    if (previousTS != 0) {
        dateCumul += (long)(CACurrentMediaTime() * 1000) - previousTS;
        previousTS = 0;
    }
    status = 0;
    NSLog(@"[AudioQueuePCMRecorder] Recording stopped");
}

void AudioQueuePCMRecorder::resumeRecorder()
{
    if (audioQueue == nil) return;
    AudioQueueStart(audioQueue, nil);
    previousTS = (long)(CACurrentMediaTime() * 1000);
    status = 2;
}

void AudioQueuePCMRecorder::pauseRecorder()
{
    if (audioQueue == nil) return;
    AudioQueuePause(audioQueue);
    if (previousTS != 0) {
        dateCumul += (long)(CACurrentMediaTime() * 1000) - previousTS;
        previousTS = 0;
    }
    status = 1;
}

NSNumber* AudioQueuePCMRecorder::recorderProgress()
{
    long r = dateCumul;
    if (previousTS != 0) r += (long)(CACurrentMediaTime() * 1000) - previousTS;
    return [NSNumber numberWithLong:r];
}

NSNumber* AudioQueuePCMRecorder::dbPeakProgress()
{
    if (nbrSamples > 0) {
        previousAmplitude = maxAmplitude;
        maxAmplitude = 0;
        nbrSamples = 0;
    }
    double max = previousAmplitude;
    if (max == 0.0) return [NSNumber numberWithDouble:0.0];
    double db = 20.0 * log10((max / 51805.5336) / 0.0002);
    return [NSNumber numberWithDouble:db];
}

int AudioQueuePCMRecorder::getStatus()
{
    return status;
}

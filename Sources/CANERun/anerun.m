// Minimal client for the private AppleNeuralEngine framework. The framework is
// loaded at runtime so binaries that do not run models never link it.

#import "anerun.h"

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

@interface _ANEModel : NSObject
@property(nonatomic, strong) NSDictionary *modelAttributes;
+ (instancetype)modelAtURL:(NSURL *)url key:(NSString *)key;
@end

@interface _ANEIOSurfaceObject : NSObject
+ (instancetype)objectWithIOSurface:(IOSurfaceRef)ioSurface;
@end

@interface _ANERequest : NSObject
+ (instancetype)requestWithInputs:(NSArray *)inputs
                     inputIndices:(NSArray *)inputIndices
                          outputs:(NSArray *)outputs
                    outputIndices:(NSArray *)outputIndices
                        perfStats:(NSArray *)perfStats
                   procedureIndex:(NSNumber *)procedureIndex;
@end

@interface _ANEClient : NSObject
+ (instancetype)sharedConnection;
- (BOOL)compileModel:(_ANEModel *)model options:(NSDictionary *)options qos:(unsigned int)qos error:(NSError **)error;
- (BOOL)loadModel:(_ANEModel *)model options:(NSDictionary *)options qos:(unsigned int)qos error:(NSError **)error;
- (BOOL)unloadModel:(_ANEModel *)model options:(NSDictionary *)options qos:(unsigned int)qos error:(NSError **)error;
- (BOOL)evaluateWithModel:(_ANEModel *)model
                  options:(NSDictionary *)options
                  request:(_ANERequest *)request
                      qos:(unsigned int)qos
                    error:(NSError **)error;
// Talks to the driver without an aned round trip.
- (BOOL)doEvaluateDirectWithModel:(_ANEModel *)model
                          options:(NSDictionary *)options
                          request:(_ANERequest *)request
                              qos:(unsigned int)qos
                            error:(NSError **)error;
- (BOOL)mapIOSurfacesWithModel:(_ANEModel *)model
                       request:(_ANERequest *)request
                cacheInference:(BOOL)cache
                         error:(NSError **)error;
- (void)unmapIOSurfacesWithModel:(_ANEModel *)model request:(_ANERequest *)request;
@end

struct anerun {
    void *client;   // _ANEClient *, retained
    void *model;    // _ANEModel *, retained
    void *request;  // _ANERequest *, retained
    void *surfaces; // NSArray of IOSurfaceRef, retained
    int mapped;     // surfaces mapped once up front
    int direct;     // doEvaluateDirect available and working
};

static const unsigned kQoS = 25;

static void fail(char *err, int errlen, NSString *what, NSError *e) {
    if (!err || errlen <= 0) return;
    NSString *msg = e ? [NSString stringWithFormat:@"%@: %@", what, e.localizedDescription] : what;
    snprintf(err, (size_t)errlen, "%s", msg.UTF8String);
}

// Size of one I/O tensor surface from the compiled model's attributes.
static size_t tensorBytes(NSDictionary *d) {
    size_t n = 0;
    if (d[@"BatchStride"] && d[@"Batches"]) {
        n = [d[@"BatchStride"] unsignedLongLongValue] * MAX(1ULL, [d[@"Batches"] unsignedLongLongValue]);
    } else if (d[@"PlaneStride"] && d[@"PlaneCount"]) {
        n = [d[@"PlaneStride"] unsignedLongLongValue] * MAX(1ULL, [d[@"PlaneCount"] unsignedLongLongValue]);
    } else if (d[@"RowStride"] && d[@"Height"]) {
        n = [d[@"RowStride"] unsignedLongLongValue] * MAX(1ULL, [d[@"Height"] unsignedLongLongValue]);
    }
    return n > 0 ? n : 0x4000;
}

static IOSurfaceRef makeSurface(size_t bytes) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth : @(bytes),
        (id)kIOSurfaceHeight : @1,
        (id)kIOSurfaceBytesPerElement : @1,
        (id)kIOSurfaceBytesPerRow : @(bytes),
        (id)kIOSurfaceAllocSize : @(bytes),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

anerun *anerun_open(const char *model_dir, char *err, int errlen) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine", RTLD_LAZY)) {
            fail(err, errlen, @"cannot load AppleNeuralEngine.framework", nil);
            return NULL;
        }
        Class clientClass = NSClassFromString(@"_ANEClient");
        Class modelClass = NSClassFromString(@"_ANEModel");
        Class surfaceClass = NSClassFromString(@"_ANEIOSurfaceObject");
        Class requestClass = NSClassFromString(@"_ANERequest");
        if (!clientClass || !modelClass || !surfaceClass || !requestClass) {
            fail(err, errlen, @"AppleNeuralEngine classes not found", nil);
            return NULL;
        }

        _ANEClient *client = [clientClass sharedConnection];
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:model_dir] isDirectory:YES];
        _ANEModel *model = [modelClass modelAtURL:url key:@"net"];
        if (!client || !model) {
            fail(err, errlen, @"cannot create ANE client or model", nil);
            return NULL;
        }
        NSDictionary *opts = @{@"kANEFModelType" : @"kANEFModelMIL"};
        NSError *e = nil;
        if (![client compileModel:model options:opts qos:kQoS error:&e]) {
            fail(err, errlen, @"compile failed", e);
            return NULL;
        }
        if (![client loadModel:model options:opts qos:kQoS error:&e]) {
            fail(err, errlen, @"load failed", e);
            return NULL;
        }

        NSArray *status = model.modelAttributes[@"NetworkStatusList"];
        NSArray *ins = status.count ? status[0][@"LiveInputList"] : nil;
        NSArray *outs = status.count ? status[0][@"LiveOutputList"] : nil;
        if (ins.count == 0 || outs.count == 0) {
            fail(err, errlen, @"compiled model reports no inputs or outputs", nil);
            [client unloadModel:model options:@{} qos:kQoS error:nil];
            return NULL;
        }
        NSMutableArray *surfaces = [NSMutableArray array];
        NSMutableArray *inObjs = [NSMutableArray array], *inIdx = [NSMutableArray array];
        NSMutableArray *outObjs = [NSMutableArray array], *outIdx = [NSMutableArray array];
        for (NSUInteger i = 0; i < ins.count; i++) {
            IOSurfaceRef s = makeSurface(tensorBytes(ins[i]));
            [surfaces addObject:(__bridge_transfer id)s];
            [inObjs addObject:[surfaceClass objectWithIOSurface:s]];
            [inIdx addObject:@(i)];
        }
        for (NSUInteger i = 0; i < outs.count; i++) {
            IOSurfaceRef s = makeSurface(tensorBytes(outs[i]));
            [surfaces addObject:(__bridge_transfer id)s];
            [outObjs addObject:[surfaceClass objectWithIOSurface:s]];
            [outIdx addObject:@(i)];
        }
        _ANERequest *request = [requestClass requestWithInputs:inObjs
                                                  inputIndices:inIdx
                                                       outputs:outObjs
                                                 outputIndices:outIdx
                                                     perfStats:nil
                                                procedureIndex:@0];
        if (!request) {
            fail(err, errlen, @"cannot build ANE request", nil);
            [client unloadModel:model options:@{} qos:kQoS error:nil];
            return NULL;
        }

        anerun *r = calloc(1, sizeof(*r));
        // Mapping the surfaces once saves a remap on every evaluation.
        SEL mapSel = @selector(mapIOSurfacesWithModel:request:cacheInference:error:);
        if ([client respondsToSelector:mapSel]) {
            r->mapped = [client mapIOSurfacesWithModel:model request:request cacheInference:YES error:nil] ||
                        [client mapIOSurfacesWithModel:model request:request cacheInference:NO error:nil];
        }
        r->direct = [client respondsToSelector:@selector(doEvaluateDirectWithModel:options:request:qos:error:)];
        if (getenv("ANERUN_DEBUG")) fprintf(stderr, "anerun: mapped=%d direct=%d\n", r->mapped, r->direct);
        r->client = (__bridge_retained void *)client;
        r->model = (__bridge_retained void *)model;
        r->request = (__bridge_retained void *)request;
        r->surfaces = (__bridge_retained void *)surfaces;
        return r;
    }
}

int anerun_eval(anerun *r, char *err, int errlen) {
    @autoreleasepool {
        _ANEClient *client = (__bridge _ANEClient *)r->client;
        _ANEModel *model = (__bridge _ANEModel *)r->model;
        _ANERequest *request = (__bridge _ANERequest *)r->request;
        NSError *e = nil;
        if (r->direct) {
            if ([client doEvaluateDirectWithModel:model options:@{} request:request qos:kQoS error:&e]) return 0;
            if (getenv("ANERUN_DEBUG")) fprintf(stderr, "anerun: direct evaluate refused: %s\n", e.localizedDescription.UTF8String);
            r->direct = 0; // fall back for good if the direct path is refused
        }
        if (![client evaluateWithModel:model options:@{} request:request qos:kQoS error:&e]) {
            fail(err, errlen, @"evaluate failed", e);
            return -1;
        }
        return 0;
    }
}

void anerun_close(anerun *r) {
    if (!r) return;
    @autoreleasepool {
        _ANEClient *client = (__bridge_transfer _ANEClient *)r->client;
        _ANEModel *model = (__bridge_transfer _ANEModel *)r->model;
        _ANERequest *request = (__bridge_transfer _ANERequest *)r->request;
        if (r->mapped) [client unmapIOSurfacesWithModel:model request:request];
        [client unloadModel:model options:@{} qos:kQoS error:nil];
        (void)(__bridge_transfer id)r->surfaces;
    }
    free(r);
}

//
//  SocketIOProxyClientOC.m
//  ourtimes
//
//  Created by bleach on 16/2/8.
//  Copyright © 2016年 YY. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "SocketIOProxyClientOC.h"
#import "SRWebSocket.h"
#import "PushIdGeneratorBaseOc.h"
#import "SocketStringReaderOc.h"
#import "SocketPacketOc.h"
#import "MisakaSocketOcEvent.h"

NSString * const kAnonymousTag = @"anonymous";

typedef NS_ENUM(NSUInteger, KeepAliveState) {
    KeepAlive_Disconnected,
    KeepAlive_Connecting,
    KeepAlive_Connected,
};

typedef NS_ENUM(NSUInteger, ProtocolDataType) {
    ProtocolData_Base64 = 1,
    ProtocolData_MsgPack = 2,
};

@interface SocketIOProxyClientOC()<SRWebSocketDelegate>

@property (nonatomic, strong) SRWebSocket* webSocket;
@property (nonatomic, strong) NSURLRequest* urlRequest;

@property (nonatomic) NSTimeInterval retryElapse;

@property (nonatomic) KeepAliveState keepAliveState;

@property (nonatomic, strong) NSString* deviceToken;

@property (nonatomic, strong) NSMutableDictionary* broadcastTopics;
@property (nonatomic, strong) NSMutableDictionary* topicToLastPacketId;
@property (nonatomic, strong) NSString* lastUnicastId;

@property (nonatomic, strong) NSTimer* reconnectTimer;
@property (nonatomic, strong) NSTimer* pingTimer;
@property (nonatomic, strong) NSTimer* pingTimeoutTimer;

@property (nonatomic, strong) NSString* sid;
@property (nonatomic, assign) BOOL upgradeWs;
@property (nonatomic, assign) CGFloat pingInterval;
@property (nonatomic, assign) CGFloat pingTimeout;

@property (nonatomic, assign) NSUInteger version;
@property (nonatomic, strong) NSString* platform;

@property (nonatomic, assign) NSUInteger reconnectionAttempts;
@property (nonatomic, assign) Boolean reconnection;
@property (nonatomic, assign) NSUInteger reconnectCount;
@property (nonatomic, assign) NSUInteger reconnectInterval;

@end

@implementation SocketIOProxyClientOC

+ (instancetype)initWith:(NSString *)url {
    SocketIOProxyClientOC* keepAlive = [[SocketIOProxyClientOC alloc] init];
    [keepAlive initWith:url];
    return keepAlive;
}

- (void)initWith:(NSString *)url {
    _retryElapse = 1.0f;
    _pingInterval = 0;
    _pingTimeout = 0;
    _version = ProtocolData_Base64;
    _platform = @"iOS";
    
    _reconnection = YES;
    _reconnectionAttempts = NSUIntegerMax;
    _reconnectCount = 0;
    _reconnectInterval = 5;
    
    NSURLRequest* request = [NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/socket.io/?transport=websocket", url]]];
    _urlRequest = request;
    _broadcastTopics = [[NSMutableDictionary alloc] initWithCapacity:10];
    _topicToLastPacketId = [[NSMutableDictionary alloc] initWithCapacity:10];
    
    _webSocket = [[SRWebSocket alloc] initWithURLRequest:_urlRequest protocols:nil allowsUntrustedSSLCertificates:YES];
    _webSocket.delegate = self;
    _pushId = [PushIdGeneratorBaseOc generatePushId];
    
    _keepAliveState = KeepAlive_Connecting;
    [_webSocket open];
}

- (void)dealloc {
    _keepAliveState = KeepAlive_Disconnected;
    [_webSocket close];
}

#pragma mark - Export
- (void)onApnToken:(NSString *)deviceToken {
    if(deviceToken){
        _deviceToken = [[[deviceToken stringByReplacingOccurrencesOfString: @"<" withString: @""]
                                         stringByReplacingOccurrencesOfString: @">" withString: @""]
                                        stringByReplacingOccurrencesOfString: @" " withString: @""];
        [self sendApnTokenToServer];
    }
}

- (void)addTag:(NSString *)tag {
    if (_keepAliveState == KeepAlive_Connected && tag != nil) {
        [self sendToServer:@[@"addTag", @{@"tag":tag}]];
    }
}

- (void)removeTag:(NSString *)tag {
    if (_keepAliveState == KeepAlive_Connected && tag != nil) {
        [self sendToServer:@[@"removeTag", @{@"tag":tag}]];
    }
}

- (void)subscribeBroadcast:(NSString *)topic {
    [self subscribeBroadcast:topic receiveTtlPackets:NO];
}

- (void)subscribeBroadcast:(NSString *)topic receiveTtlPackets:(BOOL)receiveTtlPackets {
    if (!topic) {
        return;
    }
    if (![_broadcastTopics objectForKey:topic]) {
        [_broadcastTopics setObject:@(receiveTtlPackets) forKey:topic];
        if (_keepAliveState == KeepAlive_Connected) {
            NSString* lastPacketId = [_topicToLastPacketId objectForKey:topic];
            if (lastPacketId != nil && receiveTtlPackets) {
                [self sendToServer:@[@"subscribeTopic", @{@"topic":topic, @"lastPacketId":lastPacketId}]];
            } else {
                [self sendToServer:@[@"subscribeTopic", @{@"topic":topic}]];
            }
        }
    }
}

- (void)unsubscribeBroadcast:(NSString *)topic {
    if (!topic) {
        return;
    }
    [_broadcastTopics removeObjectForKey:topic];
    [_topicToLastPacketId removeObjectForKey:topic];
    if (_keepAliveState == KeepAlive_Connected) {
        [self sendToServer:@[@"unsubscribeTopic", @{@"topic":topic}]];
    }
}

- (void)keepInBackground {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            
        }];
        NSLog(@"SocketIOProxyClient begin background task \(UIApplication.sharedApplication().backgroundTimeRemaining)");
    });
}

- (void)request:(NSString*)path data:(NSData*)data {
    // 转换到base64
    NSString *base64String = [data base64EncodedStringWithOptions:0];
    
    if (data == nil || base64String.length == 0) {
        [self sendToServer:@[@"packetProxy", @{@"path":path, @"sequenceId":[PushIdGeneratorBaseOc randomAlphaNumeric:32]}]];
    } else {
        [self sendToServer:@[@"packetProxy", @{@"data": base64String, @"path":path, @"sequenceId":[PushIdGeneratorBaseOc randomAlphaNumeric:32]}]];
    }
}

- (void)unbindUid {
    [self sendToServer:@[@"unbindUid"]];
}

#pragma --mark inner
- (void)sendToServer:(id)data {
    if (_keepAliveState != KeepAlive_Connected) {
        [self log:@"info" format:@"sendToServer is not connected"];
        [self stopReconnectTimer];
        _keepAliveState = KeepAlive_Disconnected;
        [self retryConnect];
        return;
    }
    
    SocketPacketOc* packet = [SocketPacketOc packetFromEmit:data Id:-1 nsp:@"/" ack:NO];
    NSString* packetString = [NSString stringWithFormat:@"%ld%@", (long)Message, [packet packetString]];
    
    if (_webSocket.readyState != SR_CONNECTING) {
        [_webSocket send:packetString];
    } else {
        [self log:@"info" format:@"sendToServer is connecting"];
    }
}

- (void)writeDataToServer:(NSString*)msg type:(PacketFrameType)type data:(NSArray*)datas {
    if (_keepAliveState != KeepAlive_Connected) {
        [self log:@"info" format:@"sendToServer is not connected"];
        return;
    }
    
    NSMutableString* dataString = [[NSMutableString alloc] initWithString:msg];
    [dataString insertString:[NSString stringWithFormat:@"%ld", (long)type] atIndex:0];
    [_webSocket send:dataString];
}

- (void)sendApnTokenToServer {
    if (_keepAliveState == KeepAlive_Connected && _deviceToken != nil && _pushId != nil) {
        NSString* bundleId = [[NSBundle mainBundle] bundleIdentifier];
        [self sendToServer:@[@"apnToken", @{@"apnToken":_deviceToken, @"pushId":_pushId, @"bundleId":bundleId.length ? bundleId : @""}]];
        NSLog(@"sendApnTokenToServer");
    }
}

- (void)sendPushIdAndTopicToServer {
    if (_keepAliveState == KeepAlive_Connected  && _pushId != nil) {
        NSArray* packet = nil;
        NSMutableDictionary* pushIdAndTopicDict = [[NSMutableDictionary alloc] initWithCapacity:10];
        if (_broadcastTopics.count > 0) {
            NSMutableArray* topicArray = [[NSMutableArray alloc] initWithCapacity:_broadcastTopics.count];
            for (NSString* topic in _broadcastTopics) {
                [topicArray addObject:topic];
            }
            
            [pushIdAndTopicDict setObject:topicArray forKey:@"topics"];
        }
        
        [pushIdAndTopicDict setObject:_pushId forKey:@"id"];
        [pushIdAndTopicDict setObject:@(_version) forKey:@"version"];
        [pushIdAndTopicDict setObject:_platform forKey:@"platform"];
        
        if (_topicToLastPacketId.count > 0) {
            [pushIdAndTopicDict setObject:_topicToLastPacketId forKey:@"lastPacketIds"];
        }
        if (_lastUnicastId) {
            [pushIdAndTopicDict setObject:_lastUnicastId forKey:@"lastUnicastId"];
        }
        
        packet = @[@"pushId", pushIdAndTopicDict];
        
        [self sendToServer:packet];
    }
}

- (void)updateLastPacketId:(NSString*)packetId ttl:(NSObject*)ttl unicast:(NSObject*)unicast topic:(NSString*)topic {
    BOOL reciveTtl = [[_broadcastTopics objectForKey:topic] boolValue];
    if (packetId != nil && ttl != nil) {
        [self log:@"info" format:@"on push topic = %@ pushId = %@", topic, packetId];
        if ([[NSNumber numberWithInteger:1] isEqual:unicast]) {
            _lastUnicastId = packetId;
        } else if (reciveTtl) {
            [_topicToLastPacketId setObject:packetId forKey:topic];
        }
    }
}

#pragma mark - SRWebSocketDelegate

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message {
    if (message != nil) {
        [self parseReceiveMessage:message];
        if(_keepAliveState == KeepAlive_Connected){
            [self onHeartbeat];
        }
    }
}

#pragma --mark message parser
- (void)parseReceiveMessage:(id)message {
    PacketFrameType frameType = UnKnown;
    
    if ([message isKindOfClass:[NSString class]]) {
        SocketStringReaderOc* msgReader = [[SocketStringReaderOc alloc] initWithMessage:message];
        NSString* type = [msgReader currentCharacter];
        frameType = (PacketFrameType)[type integerValue];
    }
    
    switch (frameType) {
        case Message:
        {
           [self handleMessageBase64:message];
        }
            break;
        case Noop:
        {
            [self handleNOOP];
        }
            break;
        case Pong:
        {
            if (![message isKindOfClass:[NSString class]]) {
                [self log:@"info" format:@"错误的长连接类型%ld", (long)frameType];
                return;
            }
            [self handlePong:message];
        }
            break;
        case Open:
        {
            if (![message isKindOfClass:[NSString class]]) {
                [self log:@"info" format:@"错误的长连接类型%ld", (long)frameType];
                return;
            }
            [self handleOpen:message];
        }
            break;
        case Close:
        {
            [self handleClose];
        }
            break;
        default:
        {
            NSLog(@"Got unknown packet type = %ld", (long)frameType);
        }
            break;
    }
}

- (void)handleMessageBase64:(NSString*)message {
    NSString* realMessage = [message substringFromIndex:1];
    
    NSInteger packetType = -1;
    if (realMessage.length > 1) {
        packetType = [[realMessage substringWithRange:NSMakeRange(0, 1)] integerValue];
    }
    
    if (packetType < Connect) {
        [self log:@"info" format:@"错误的长连接%@" ,realMessage];
        return;
    }
    
    realMessage = [realMessage substringFromIndex:1];
    
    NSError *error;
    
    NSArray *result = [NSJSONSerialization JSONObjectWithData:[realMessage dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:&error];
    if (error) {
        NSLog(@"JSONObjectWithData error: %@", error);
        return;
    }
    
    if (![result isKindOfClass:[NSArray class]] || result.count < 2) {
        [self log:@"info" format:@"错误的长连接解析%@", realMessage];
        return;
    }
    
    if([@"push" isEqualToString:[result objectAtIndex:0]]){
        NSDictionary* pushDictionary = [result objectAtIndex:1];
        if (![pushDictionary isKindOfClass:[NSDictionary class]]) {
            [self log:@"info" format:@"错误的长连接数据%@", realMessage];
            return;
        }
        
        NSString* topic = [pushDictionary objectForKey:@"topic"];
        NSString* packetId = [pushDictionary objectForKey:@"id"];
        if (!packetId) {
            packetId = [pushDictionary objectForKey:@"i"];
        }
        NSString* dataBase64 = [pushDictionary objectForKey:@"data"];
        if(dataBase64 == nil){
            dataBase64 = [pushDictionary objectForKey:@"d"];
        }
        NSObject *ttl = [pushDictionary objectForKey:@"ttl"];
        if(!ttl){
            ttl = [pushDictionary objectForKey:@"t"];
        }
        NSObject *unicast = [pushDictionary objectForKey:@"unicast"];
        if(!unicast){
            unicast = [pushDictionary objectForKey:@"u"];
        }
        
        [self updateLastPacketId:packetId ttl:ttl unicast:unicast topic:topic];
        NSData *data;
        if(dataBase64) {
            data = [[NSData alloc] initWithBase64EncodedString:dataBase64 options:0];
        } else {
            NSObject *json = [pushDictionary objectForKey:@"j"];
            if(json){
                if ([json isKindOfClass:[NSDictionary class]] || [json isKindOfClass:[NSArray class]]) {
                    data = [NSJSONSerialization dataWithJSONObject:json
                                                           options:((NSJSONWritingOptions) 0)
                                                             error:&error];
                } else {
                    return;
                }
            }
        }
        
        if (_pushCallbackDelegate && [_pushCallbackDelegate respondsToSelector:@selector(onPush:)]) {
            [_pushCallbackDelegate onPush:data];
        }
    } else if([@"p" isEqualToString:[result objectAtIndex:0]]) {
        if([result count] > 2){
            NSArray *ttlArray = [result objectAtIndex:2];
            if(ttlArray != nil){
                NSString* topic = [ttlArray objectAtIndex:0];
                NSString* packetId = [ttlArray objectAtIndex:1];
                NSObject* unicast = [ttlArray objectAtIndex:2];
                [self updateLastPacketId:packetId ttl:@"" unicast:unicast topic:topic];
            }
        }
        
        NSData *data = [self elementToJsonData:[result objectAtIndex:1]];
        
        if (_pushCallbackDelegate && [_pushCallbackDelegate respondsToSelector:@selector(onPush:)]) {
            [_pushCallbackDelegate onPush:data];
        }
    } else if ([@"pushId" isEqualToString:[result objectAtIndex:0]]) {
        NSDictionary* pushDictionary = [result objectAtIndex:1];
        if (![pushDictionary isKindOfClass:[NSDictionary class]]) {
            [self log:@"info" format:@"错误的长连接数据%@", realMessage];
            return;
        }
        NSString* uid = [pushDictionary objectForKey:@"uid"];
        NSArray* tags = [pushDictionary objectForKey:@"tags"];

        if (_pushCallbackDelegate && [_pushCallbackDelegate respondsToSelector:@selector(onReceivePushId:tags:)]) {
            [_pushCallbackDelegate onReceivePushId:uid tags:tags];
        }
    }
}

-(NSData*) elementToJsonData:(NSObject*)element {
    if([element isKindOfClass:[NSString class]]) {
        return [(NSString*)element dataUsingEncoding:NSUTF8StringEncoding];
    } else if([element isKindOfClass:[NSDictionary class]] || [element isKindOfClass:[NSArray class]]){
        NSError *error;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:element
                                                           options:(NSJSONWritingOptions) 0
                                                             error:&error];
        return jsonData;
    } else {
        return [@"" dataUsingEncoding:NSUTF8StringEncoding];
    }
}

- (void)handleNOOP {
    [self log:@"info" format:@"handleNOOP"];
}

- (void)handlePong:(NSString*)pongMessage {
    [self log:@"info" format:@"handlePong = %@", pongMessage];
    [self setPing];
    
    // We should upgrade
    if ([pongMessage isEqualToString:@"3probe"]) {
        [self log:@"info" format:@"3probe"];
    }
}

- (void)handleOpen:(NSString*)message {
    NSString* realMessage = [message substringFromIndex:1];
    NSError *error;
    NSDictionary *openDictionary = [NSJSONSerialization JSONObjectWithData:[realMessage dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:&error];
    if (error) {
        NSLog(@"handleOpen parseError: %@", error);
        return;
    }
    
    if (openDictionary == nil) {
        NSLog(@"handleOpen parseError = %@", realMessage);
        return;
    }
    //realMessage	__NSCFString *	@"{\"sid\":\"haziiITL5WZwf5thAAt6\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":25000}"	0x00007fe70af59d40
    NSString* sid = [openDictionary objectForKey:@"sid"];
    NSArray* upgrades = [openDictionary objectForKey:@"upgrades"];
    NSString* pingInterval = [openDictionary objectForKey:@"pingInterval"];
    NSString* pingTimeout = [openDictionary objectForKey:@"pingTimeout"];
    
    _sid = sid;
    if (upgrades.count > 0) {
        if ([upgrades containsObject:@"websocket"]) {
            _upgradeWs = YES;
        } else {
            _upgradeWs = NO;
        }
    }

    _pingInterval = [pingInterval floatValue] / 1000.0f;
    _pingTimeout = [pingTimeout floatValue] / 1000.0f;
    
    [self setPing];
}

- (void)setPing {
    if (_pingInterval > 0) {
        if (_pingTimer != nil) {
            [_pingTimer invalidate];
            _pingTimer = nil;
        }
        
        WeakSelf();
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.pingTimer = [NSTimer scheduledTimerWithTimeInterval:weakSelf.pingInterval target:weakSelf selector:@selector(sendPing) userInfo:nil repeats:NO];
        });
    }

}

- (void)sendPing {
    [self writeDataToServer:@"" type:Ping data:nil];
    [self onHeartbeat];
}

- (void)onHeartbeat {
    if (_pingTimeoutTimer != nil) {
        [_pingTimeoutTimer invalidate];
        _pingTimeoutTimer = nil;
    }
    
    if(_pingTimeout <= 0) {
        _pingTimeout = _pingInterval;
    }
    WeakSelf();
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.pingTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:weakSelf.pingTimeout target:weakSelf selector:@selector(errorPing) userInfo:nil repeats:NO];
    });
}

- (void)errorPing {
    NSLog(@"socket error ping closeConnect");
    [[NSNotificationCenter defaultCenter] postNotificationName:kMisakaSocketOcDidDisconnectNotification object:nil];
    [self closeConnect];
    [self log:@"info" format:@"Ping timeout"];

}

- (void)handleClose {
    [self log:@"info" format:@"webSocketDidClose"];
    [self closeConnect];
}


- (void)retryConnect {
    // 保持重开。
    WeakSelf()
    if(weakSelf.reconnection == NO || weakSelf.reconnectCount >= _reconnectionAttempts) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_retryElapse * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf log:@"info" format:@"长连接重连。。。"];
        if (weakSelf.keepAliveState != KeepAlive_Disconnected) {
            [weakSelf log:@"info" format:@"正在连接中。。。%lu", (unsigned long)weakSelf.keepAliveState];
            return;
        }
        if (weakSelf.pingTimer != nil) {
            [weakSelf.pingTimer invalidate];
            weakSelf.pingTimer = nil;
        }
        if (weakSelf.pingTimeoutTimer != nil) {
            [weakSelf.pingTimeoutTimer invalidate];
            weakSelf.pingTimeoutTimer = nil;
        }
        [weakSelf stopReconnectTimer];
        weakSelf.reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:weakSelf.reconnectInterval target:weakSelf selector:@selector(retryConnect) userInfo:nil repeats:NO];
        if (weakSelf.webSocket) {
            weakSelf.webSocket.delegate = nil;
            [weakSelf.webSocket close];
            weakSelf.webSocket = nil;
        }
        weakSelf.reconnectCount++;
        weakSelf.webSocket = [[SRWebSocket alloc] initWithURLRequest:weakSelf.urlRequest protocols:nil allowsUntrustedSSLCertificates:YES];
        weakSelf.webSocket.delegate = weakSelf;
        weakSelf.keepAliveState = KeepAlive_Connecting;
        [weakSelf.webSocket open];
    });
}

- (void)closeConnect {
    WeakSelf()
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_retryElapse * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        weakSelf.keepAliveState = KeepAlive_Disconnected;
        if (weakSelf.pingTimer != nil) {
            [weakSelf.pingTimer invalidate];
            weakSelf.pingTimer = nil;
        }
        if (weakSelf.pingTimeoutTimer != nil) {
            [weakSelf.pingTimeoutTimer invalidate];
            weakSelf.pingTimeoutTimer = nil;
        }
        [weakSelf.webSocket close];
        [weakSelf retryConnect];
    });
}

- (void)stopReconnectTimer {
    if (_reconnectTimer != nil) {
        [_reconnectTimer invalidate];
        _reconnectTimer = nil;
    }
}

- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
    [self log:@"info" format:@"webSocketDidOpen"];
    [[NSNotificationCenter defaultCenter] postNotificationName:kMisakaSocketOcDidConnectNotification object:nil];
    WeakSelf()
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf stopReconnectTimer];
        weakSelf.keepAliveState = KeepAlive_Connected;
        weakSelf.reconnectCount = 0;
        [weakSelf sendPushIdAndTopicToServer];
        [weakSelf sendApnTokenToServer];
    });
}

- (void)log:(NSString*)level format:(NSString*)format, ...{
    va_list args;
    va_start(args, format);
    if (_pushCallbackDelegate && [_pushCallbackDelegate respondsToSelector:@selector(log:format:args:)]){
         [_pushCallbackDelegate log:level format:format args:args];
    }
    va_end(args);
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
    [self log:@"info" format:@"webSocketDidFailed = %ld", (long)error.code];
    [[NSNotificationCenter defaultCenter] postNotificationName:kMisakaSocketOcDidDisconnectNotification object:nil];
    WeakSelf()
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf stopReconnectTimer];
        weakSelf.keepAliveState = KeepAlive_Disconnected;
        [weakSelf retryConnect];
    });
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    [self log:@"info" format:@"webSocketDidClose reason = %@", reason];
    [[NSNotificationCenter defaultCenter] postNotificationName:kMisakaSocketOcDidDisconnectNotification object:nil];
    WeakSelf()
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf stopReconnectTimer];
        weakSelf.keepAliveState = KeepAlive_Disconnected;
        [weakSelf retryConnect];
    });
}


@end

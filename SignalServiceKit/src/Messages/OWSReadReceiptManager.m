//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSReadReceiptManager.h"
#import "AppReadiness.h"
#import "OWSLinkedDeviceReadReceipt.h"
#import "OWSMessageSender.h"
#import "OWSOutgoingReceiptManager.h"
#import "OWSReadReceiptsForLinkedDevicesMessage.h"
#import "OWSReceiptsForSenderMessage.h"
#import "OWSStorage.h"
#import "SSKEnvironment.h"
#import "TSAccountManager.h"
#import "TSContactThread.h"
#import "TSDatabaseView.h"
#import "TSIncomingMessage.h"
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalCoreKit/Threading.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const kIncomingMessageMarkedAsReadNotification = @"kIncomingMessageMarkedAsReadNotification";

@implementation TSRecipientReadReceipt

+ (NSString *)collection
{
    return @"TSRecipientReadReceipt2";
}

- (instancetype)initWithSentTimestamp:(uint64_t)sentTimestamp
{
    OWSAssertDebug(sentTimestamp > 0);

    self = [super initWithUniqueId:[TSRecipientReadReceipt uniqueIdForSentTimestamp:sentTimestamp]];

    if (self) {
        _sentTimestamp = sentTimestamp;
        _recipientMap = [NSDictionary new];
    }

    return self;
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithUniqueId:(NSString *)uniqueId
                    recipientMap:(NSDictionary<NSString *,NSNumber *> *)recipientMap
                   sentTimestamp:(uint64_t)sentTimestamp
{
    self = [super initWithUniqueId:uniqueId];

    if (!self) {
        return self;
    }

    _recipientMap = recipientMap;
    _sentTimestamp = sentTimestamp;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

+ (NSString *)uniqueIdForSentTimestamp:(uint64_t)timestamp
{
    return [NSString stringWithFormat:@"%llu", timestamp];
}

- (void)addRecipientId:(NSString *)recipientId timestamp:(uint64_t)timestamp
{
    OWSAssertDebug(recipientId.length > 0);
    OWSAssertDebug(timestamp > 0);

    NSMutableDictionary<NSString *, NSNumber *> *recipientMapCopy = [self.recipientMap mutableCopy];
    recipientMapCopy[recipientId] = @(timestamp);
    _recipientMap = [recipientMapCopy copy];
}

+ (void)addRecipientId:(NSString *)recipientId
         sentTimestamp:(uint64_t)sentTimestamp
         readTimestamp:(uint64_t)readTimestamp
           transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    NSString *uniqueId = [self uniqueIdForSentTimestamp:sentTimestamp];
    TSRecipientReadReceipt *_Nullable recipientReadReceipt =
        [TSRecipientReadReceipt anyFetchWithUniqueId:uniqueId transaction:transaction];
    if (!recipientReadReceipt) {
        recipientReadReceipt = [[TSRecipientReadReceipt alloc] initWithSentTimestamp:sentTimestamp];
        [recipientReadReceipt addRecipientId:recipientId timestamp:readTimestamp];
        [recipientReadReceipt anyInsertWithTransaction:transaction];
    } else {
        [recipientReadReceipt
            anyUpdateWithTransaction:transaction
                               block:^(TSRecipientReadReceipt *recipientReadReceipt) {
                                   [recipientReadReceipt addRecipientId:recipientId timestamp:readTimestamp];
                               }];
    }
}

+ (nullable NSDictionary<NSString *, NSNumber *> *)recipientMapForSentTimestamp:(uint64_t)sentTimestamp
                                                                    transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    NSString *uniqueId = [self uniqueIdForSentTimestamp:sentTimestamp];
    TSRecipientReadReceipt *_Nullable recipientReadReceipt =
        [TSRecipientReadReceipt anyFetchWithUniqueId:uniqueId transaction:transaction];
    return recipientReadReceipt.recipientMap;
}

+ (void)removeRecipientIdsForTimestamp:(uint64_t)sentTimestamp transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    NSString *uniqueId = [self uniqueIdForSentTimestamp:sentTimestamp];
    TSRecipientReadReceipt *_Nullable recipientReadReceipt =
        [TSRecipientReadReceipt anyFetchWithUniqueId:uniqueId transaction:transaction];
    if (recipientReadReceipt != nil) {
        [recipientReadReceipt anyRemoveWithTransaction:transaction];
    }
}

@end

#pragma mark -

NSString *const OWSReadReceiptManagerCollection = @"OWSReadReceiptManagerCollection";
NSString *const OWSReadReceiptManagerAreReadReceiptsEnabled = @"areReadReceiptsEnabled";

@interface OWSReadReceiptManager ()

// A map of "thread unique id"-to-"read receipt" for read receipts that
// we will send to our linked devices.
//
// Should only be accessed while synchronized on the OWSReadReceiptManager.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, OWSLinkedDeviceReadReceipt *> *toLinkedDevicesReadReceiptMap;

// Should only be accessed while synchronized on the OWSReadReceiptManager.
@property (nonatomic) BOOL isProcessing;

@property (atomic) NSNumber *areReadReceiptsEnabledCached;

@end

#pragma mark -

@implementation OWSReadReceiptManager

+ (SDSKeyValueStore *)keyValueStore
{
    static SDSKeyValueStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SDSKeyValueStore alloc] initWithCollection:OWSReadReceiptManagerCollection];
    });
    return instance;
}

+ (instancetype)sharedManager
{
    OWSAssert(SSKEnvironment.shared.readReceiptManager);

    return SSKEnvironment.shared.readReceiptManager;
}

- (instancetype)init
{
    self = [super init];

    if (!self) {
        return self;
    }

    _toLinkedDevicesReadReceiptMap = [NSMutableDictionary new];

    OWSSingletonAssert();

    // Start processing.
    [AppReadiness runNowOrWhenAppDidBecomeReady:^{
        [self scheduleProcessing];
    }];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Dependencies

- (MessageSenderJobQueue *)messageSenderJobQueue
{
    return SSKEnvironment.shared.messageSenderJobQueue;
}

- (OWSOutgoingReceiptManager *)outgoingReceiptManager
{
    OWSAssertDebug(SSKEnvironment.shared.outgoingReceiptManager);

    return SSKEnvironment.shared.outgoingReceiptManager;
}

- (SDSDatabaseStorage *)databaseStorage
{
    return SDSDatabaseStorage.shared;
}

#pragma mark -

// Schedules a processing pass, unless one is already scheduled.
- (void)scheduleProcessing
{
    OWSAssertDebug(AppReadiness.isAppReady);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized(self)
        {
            if (self.isProcessing) {
                return;
            }

            self.isProcessing = YES;

            [self process];
        }
    });
}

- (void)process
{
    @synchronized(self)
    {
        OWSLogVerbose(@"Processing read receipts.");

        NSArray<OWSLinkedDeviceReadReceipt *> *readReceiptsForLinkedDevices =
            [self.toLinkedDevicesReadReceiptMap allValues];
        [self.toLinkedDevicesReadReceiptMap removeAllObjects];
        if (readReceiptsForLinkedDevices.count > 0) {
            OWSReadReceiptsForLinkedDevicesMessage *message =
                [[OWSReadReceiptsForLinkedDevicesMessage alloc] initWithReadReceipts:readReceiptsForLinkedDevices];

            [self.databaseStorage writeWithBlock:^(SDSAnyWriteTransaction *transaction) {
                [self.messageSenderJobQueue addMessage:message transaction:transaction];
            }];
        }

        BOOL didWork = readReceiptsForLinkedDevices.count > 0;

        if (didWork) {
            // Wait N seconds before processing read receipts again.
            // This allows time for a batch to accumulate.
            //
            // We want a value high enough to allow us to effectively de-duplicate,
            // read receipts without being so high that we risk not sending read
            // receipts due to app exit.
            const CGFloat kProcessingFrequencySeconds = 3.f;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kProcessingFrequencySeconds * NSEC_PER_SEC)),
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                ^{
                    [self process];
                });
        } else {
            self.isProcessing = NO;
        }
    }
}

#pragma mark - Mark as Read Locally

- (void)markAsReadLocallyBeforeSortId:(uint64_t)sortId thread:(TSThread *)thread
{
    OWSAssertDebug(thread);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.databaseStorage writeWithBlock:^(SDSAnyWriteTransaction *transaction) {
            [self markAsReadBeforeSortId:sortId
                                  thread:thread
                           readTimestamp:[NSDate ows_millisecondTimeStamp]
                                wasLocal:YES
                             transaction:transaction];
        }];
    });
}

- (void)messageWasReadLocally:(TSIncomingMessage *)message
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized(self)
        {
            NSString *threadUniqueId = message.uniqueThreadId;
            OWSAssertDebug(threadUniqueId.length > 0);

            SignalServiceAddress *messageAuthorAddress = message.authorAddress;
            OWSAssertDebug(messageAuthorAddress.isValid);

            OWSLinkedDeviceReadReceipt *newReadReceipt =
                [[OWSLinkedDeviceReadReceipt alloc] initWithSenderAddress:messageAuthorAddress
                                                       messageIdTimestamp:message.timestamp
                                                            readTimestamp:[NSDate ows_millisecondTimeStamp]];

            OWSLinkedDeviceReadReceipt *_Nullable oldReadReceipt = self.toLinkedDevicesReadReceiptMap[threadUniqueId];
            if (oldReadReceipt && oldReadReceipt.messageIdTimestamp > newReadReceipt.messageIdTimestamp) {
                // If there's an existing "linked device" read receipt for the same thread with
                // a newer timestamp, discard this "linked device" read receipt.
                OWSLogVerbose(@"Ignoring redundant read receipt for linked devices.");
            } else {
                OWSLogVerbose(@"Enqueuing read receipt for linked devices.");
                self.toLinkedDevicesReadReceiptMap[threadUniqueId] = newReadReceipt;
            }

            if (message.authorAddress.isLocalAddress) {
                OWSLogVerbose(@"Ignoring read receipt for self-sender.");
                return;
            }

            if ([self areReadReceiptsEnabled]) {
                OWSLogVerbose(@"Enqueuing read receipt for sender.");
                [self.outgoingReceiptManager enqueueReadReceiptForAddress:messageAuthorAddress
                                                                timestamp:message.timestamp];
            }

            [self scheduleProcessing];
        }
    });
}

#pragma mark - Read Receipts From Recipient

- (void)processReadReceiptsFromRecipientId:(NSString *)recipientId
                            sentTimestamps:(NSArray<NSNumber *> *)sentTimestamps
                             readTimestamp:(uint64_t)readTimestamp
{
    OWSAssertDebug(recipientId.length > 0);
    OWSAssertDebug(sentTimestamps);

    if (![self areReadReceiptsEnabled]) {
        OWSLogInfo(@"Ignoring incoming receipt message as read receipts are disabled.");
        return;
    }

    [self.databaseStorage asyncWriteWithBlock:^(SDSAnyWriteTransaction *transaction) {
        for (NSNumber *nsSentTimestamp in sentTimestamps) {
            UInt64 sentTimestamp = [nsSentTimestamp unsignedLongLongValue];

            NSArray<TSOutgoingMessage *> *messages;
            if (transaction.transitional_yapReadTransaction) {
                messages = (NSArray<TSOutgoingMessage *> *)[TSInteraction
                    interactionsWithTimestamp:sentTimestamp
                                      ofClass:[TSOutgoingMessage class]
                              withTransaction:transaction.transitional_yapReadTransaction];
            }
            if (messages.count > 1) {
                OWSLogError(@"More than one matching message with timestamp: %llu.", sentTimestamp);
            }
            if (messages.count > 0) {
                // TODO: We might also need to "mark as read by recipient" any older messages
                // from us in that thread.  Or maybe this state should hang on the thread?
                for (TSOutgoingMessage *message in messages) {
                    [message updateWithReadRecipientId:recipientId readTimestamp:readTimestamp transaction:transaction];
                }
            } else {
                // Persist the read receipts so that we can apply them to outgoing messages
                // that we learn about later through sync messages.
                [TSRecipientReadReceipt addRecipientId:recipientId
                                         sentTimestamp:sentTimestamp
                                         readTimestamp:readTimestamp
                                           transaction:transaction];
            }
        }
    }];
}

- (void)applyEarlyReadReceiptsForOutgoingMessageFromLinkedDevice:(TSOutgoingMessage *)message
                                                     transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(message);
    OWSAssertDebug(transaction);

    uint64_t sentTimestamp = message.timestamp;
    NSDictionary<NSString *, NSNumber *> *recipientMap =
        [TSRecipientReadReceipt recipientMapForSentTimestamp:sentTimestamp transaction:transaction];
    if (!recipientMap) {
        return;
    }
    OWSAssertDebug(recipientMap.count > 0);
    for (NSString *recipientId in recipientMap) {
        NSNumber *nsReadTimestamp = recipientMap[recipientId];
        OWSAssertDebug(nsReadTimestamp);
        uint64_t readTimestamp = [nsReadTimestamp unsignedLongLongValue];

        [message updateWithReadRecipientId:recipientId readTimestamp:readTimestamp transaction:transaction];
    }
    [TSRecipientReadReceipt removeRecipientIdsForTimestamp:message.timestamp transaction:transaction];
}

#pragma mark - Linked Device Read Receipts

- (void)applyEarlyReadReceiptsForIncomingMessage:(TSIncomingMessage *)message
                                     transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(message);
    OWSAssertDebug(transaction);

    SignalServiceAddress *senderAddress = message.authorAddress;
    uint64_t timestamp = message.timestamp;
    if (!senderAddress.isValid || timestamp < 1) {
        OWSFailDebug(@"Invalid incoming message: %@ %llu", senderAddress, timestamp);
        return;
    }

    OWSLinkedDeviceReadReceipt *_Nullable readReceipt =
        [OWSLinkedDeviceReadReceipt findLinkedDeviceReadReceiptWithAddress:senderAddress
                                                        messageIdTimestamp:timestamp
                                                               transaction:transaction];
    if (!readReceipt) {
        return;
    }

    [message markAsReadAtTimestamp:readReceipt.readTimestamp sendReadReceipt:NO transaction:transaction];
    [readReceipt anyRemoveWithTransaction:transaction];
}

- (void)processReadReceiptsFromLinkedDevice:(NSArray<SSKProtoSyncMessageRead *> *)readReceiptProtos
                              readTimestamp:(uint64_t)readTimestamp
                                transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(readReceiptProtos);
    OWSAssertDebug(transaction);

    for (SSKProtoSyncMessageRead *readReceiptProto in readReceiptProtos) {
        SignalServiceAddress *_Nullable senderAddress = readReceiptProto.senderAddress;
        uint64_t messageIdTimestamp = readReceiptProto.timestamp;

        OWSAssertDebug(senderAddress.isValid);

        if (messageIdTimestamp == 0) {
            OWSFailDebug(@"messageIdTimestamp was unexpectedly 0");
            continue;
        }

        NSArray<TSIncomingMessage *> *messages;
        if (transaction.transitional_yapReadTransaction) {
            messages = (NSArray<TSIncomingMessage *> *)[TSInteraction
                interactionsWithTimestamp:messageIdTimestamp
                                  ofClass:[TSIncomingMessage class]
                          withTransaction:transaction.transitional_yapReadTransaction];
        }
        if (messages.count > 0) {
            for (TSIncomingMessage *message in messages) {
                NSTimeInterval secondsSinceRead = [NSDate new].timeIntervalSince1970 - readTimestamp / 1000;
                OWSAssertDebug([message isKindOfClass:[TSIncomingMessage class]]);
                OWSLogDebug(@"read on linked device %f seconds ago", secondsSinceRead);
                [self markAsReadOnLinkedDevice:message readTimestamp:readTimestamp transaction:transaction];
            }
        } else {
            // Received read receipt for unknown incoming message.
            // Persist in case we receive the incoming message later.
            OWSLinkedDeviceReadReceipt *readReceipt =
                [[OWSLinkedDeviceReadReceipt alloc] initWithSenderAddress:senderAddress
                                                       messageIdTimestamp:messageIdTimestamp
                                                            readTimestamp:readTimestamp];
            [readReceipt anyInsertWithTransaction:transaction];
        }
    }
}

- (void)markAsReadOnLinkedDevice:(TSIncomingMessage *)message
                   readTimestamp:(uint64_t)readTimestamp
                     transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(message);
    OWSAssertDebug(transaction);

    // Always re-mark the message as read to ensure any earlier read time is applied to disappearing messages.
    if (transaction.transitional_yapWriteTransaction) {
        [message markAsReadAtTimestamp:readTimestamp sendReadReceipt:NO transaction:transaction];
    }

    // Also mark any unread messages appearing earlier in the thread as read as well.
    [self markAsReadBeforeSortId:message.sortId
                          thread:[message threadWithTransaction:transaction]
                   readTimestamp:readTimestamp
                        wasLocal:NO
                     transaction:transaction];
}

#pragma mark - Mark As Read

- (void)markAsReadBeforeSortId:(uint64_t)sortId
                        thread:(TSThread *)thread
                 readTimestamp:(uint64_t)readTimestamp
                      wasLocal:(BOOL)wasLocal
                   transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(sortId > 0);
    OWSAssertDebug(thread);
    OWSAssertDebug(transaction);

    if (!transaction.transitional_yapWriteTransaction) {
        return;
    }

    NSMutableArray<id<OWSReadTracking>> *newlyReadList = [NSMutableArray new];

    [[TSDatabaseView unseenDatabaseViewExtension:transaction.transitional_yapReadTransaction]
        enumerateKeysAndObjectsInGroup:thread.uniqueId
                            usingBlock:^(NSString *collection, NSString *key, id object, NSUInteger index, BOOL *stop) {
                                if (![object conformsToProtocol:@protocol(OWSReadTracking)]) {
                                    OWSFailDebug(
                                        @"Expected to conform to OWSReadTracking: object with class: %@ collection: %@ "
                                        @"key: %@",
                                        [object class],
                                        collection,
                                        key);
                                    return;
                                }
                                id<OWSReadTracking> possiblyRead = (id<OWSReadTracking>)object;
                                if (possiblyRead.sortId > sortId) {
                                    *stop = YES;
                                    return;
                                }

                                OWSAssertDebug(!possiblyRead.read);
                                OWSAssertDebug(possiblyRead.expireStartedAt == 0);
                                if (!possiblyRead.read) {
                                    [newlyReadList addObject:possiblyRead];
                                }
                            }];

    if (newlyReadList.count < 1) {
        return;
    }
    
    if (wasLocal) {
        OWSLogError(@"Marking %lu messages as read locally.", (unsigned long)newlyReadList.count);
    } else {
        OWSLogError(@"Marking %lu messages as read by linked device.", (unsigned long)newlyReadList.count);
    }
    for (id<OWSReadTracking> readItem in newlyReadList) {
        if (transaction.transitional_yapWriteTransaction) {
            [readItem markAsReadAtTimestamp:readTimestamp sendReadReceipt:wasLocal transaction:transaction];
        }
    }
}

#pragma mark - Settings

- (void)prepareCachedValues
{
    [self areReadReceiptsEnabled];
}

- (BOOL)areReadReceiptsEnabled
{
    // We don't need to worry about races around this cached value.
    if (!self.areReadReceiptsEnabledCached) {
        [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
            self.areReadReceiptsEnabledCached =
                @([OWSReadReceiptManager.keyValueStore getBool:OWSReadReceiptManagerAreReadReceiptsEnabled
                                                  defaultValue:NO
                                                   transaction:transaction]);
        }];
    }

    return [self.areReadReceiptsEnabledCached boolValue];
}

- (void)setAreReadReceiptsEnabled:(BOOL)value
{
    OWSLogInfo(@"setAreReadReceiptsEnabled: %d.", value);

    [self.databaseStorage writeWithBlock:^(SDSAnyWriteTransaction *transaction) {
        [OWSReadReceiptManager.keyValueStore setBool:value
                                                 key:OWSReadReceiptManagerAreReadReceiptsEnabled
                                         transaction:transaction];
    }];

    [SSKEnvironment.shared.syncManager sendConfigurationSyncMessage];

    self.areReadReceiptsEnabledCached = @(value);
}

@end

NS_ASSUME_NONNULL_END

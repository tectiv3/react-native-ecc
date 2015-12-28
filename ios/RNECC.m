//
//  RNCryptoUtils.m
//  rnecc
//
//  Created by Mark Vayngrib on 12/24/15.
//  Copyright © 2015 Facebook. All rights reserved.
//

#import "RNECC.h"
#include "CommonCrypto/CommonDigest.h"
#import "RCTUtils.h"

#define HASH_LENGTH             CC_SHA256_DIGEST_LENGTH
#define kTypeOfSigPadding       kSecPaddingPKCS1

NSString *const RNECCErrorDomain = @"RNECCErrorDomain";

#if TARGET_OS_SIMULATOR
static BOOL isSimulator = YES;
#else
static BOOL isSimulator = NO;
#endif

@implementation RNECC

RCT_EXPORT_MODULE();

RCT_EXPORT_METHOD(test)
{
  NSDictionary* error;
  NSString* serviceId = @"this.is.a.test";
  NSString* pub = [self generateECPair:serviceId sizeInBits:@256 error:&error];
  if (pub == nil) return;

  NSMutableData* hash = [NSMutableData dataWithLength:HASH_LENGTH];
  SecRandomCopyBytes(kSecRandomDefault, HASH_LENGTH, [hash mutableBytes]);
  NSData* sig = [self sign:serviceId pub:pub hash:hash error:&error];
  if (sig == nil) return;

  BOOL verified = [self verify:pub hash:hash sig:sig error:&error];
  NSLog(@"success: %i", verified);
}

RCT_EXPORT_METHOD(generateECPair: (nonnull NSString*) serviceID
                      sizeInBits:(nonnull NSNumber*)sizeInBits
                        callback:(RCTResponseSenderBlock)callback) {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary* error;
    NSString* base64pub = [self generateECPair:serviceID sizeInBits:sizeInBits error:&error];
    if (base64pub == nil) {
      return callback(@[error]);
    } else {
      callback(@[[NSNull null], base64pub]);
    }
  });
}

/**
 * @return base64 pub key string
 */
- (NSString *) generateECPair:(nonnull NSString*) serviceID
                   sizeInBits:(nonnull NSNumber*)sizeInBits
                        error:(NSDictionary **)error
{
  CFErrorRef sacErr = NULL;
  SecAccessControlRef sacObject;

  // Should be the secret invalidated when passcode is removed? If not then use `kSecAttrAccessibleWhenUnlocked`.
  sacObject = SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                              kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
//                                              kSecAccessControlTouchIDAny | kSecAccessControlPrivateKeyUsage,
//                                              kSecAccessControlUserPresence,
                                              kNilOptions,
                                              &sacErr);

  if (sacErr) {
    *error = toRCTError((__bridge NSError *)sacErr);
    return nil;
  }

  // Create parameters dictionary for key generation.
  NSString* uuid = [self uuidString];
  NSString* pubKeyLabel = [self toPublicIdentifier:uuid];
  NSMutableDictionary *privateKeyAttrs = [NSMutableDictionary dictionaryWithDictionary: @{
                                    (__bridge id)kSecAttrIsPermanent: @YES,
                                    (__bridge id)kSecAttrApplicationLabel: uuid,
                                    }];

  if (!isSimulator) {
    [privateKeyAttrs setObject:(__bridge_transfer id)sacObject forKey:(__bridge id)kSecAttrAccessControl];
//    [privateKeyAttrs setObject:(__bridge id)kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly forKey:(__bridge id)kSecAttrAccessible];
  }

  NSDictionary *publicKeyAttrs = @{
                                   (__bridge id)kSecAttrIsPermanent: isSimulator ? @YES : @NO,
                                   (__bridge id)kSecAttrApplicationLabel: pubKeyLabel,
                                   };

  NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithDictionary: @{
                               (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeEC,
                               (__bridge id)kSecAttrKeySizeInBits: sizeInBits,
                               (__bridge id)kSecPrivateKeyAttrs: privateKeyAttrs,
                               (__bridge id)kSecPublicKeyAttrs: publicKeyAttrs,
                               }];

  if (!isSimulator && floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_8_0) {
    NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (os.majorVersion >= 9) {
      [parameters setObject:(__bridge id)kSecAttrTokenIDSecureEnclave forKey:(__bridge id)kSecAttrTokenID];
    }
  }

  SecKeyRef publicKey, privateKey;
  OSStatus status = SecKeyGeneratePair((__bridge CFDictionaryRef)parameters, &publicKey, &privateKey);
  if (status != errSecSuccess) {
    *error = makeError(status, nil);
    return nil;
  }

  if (!isSimulator) {
    status = SecItemAdd((__bridge CFDictionaryRef)@{
                                             (__bridge id)kSecClass: (__bridge id)kSecClassKey,
                                             (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
                                             (__bridge id)kSecAttrApplicationLabel: pubKeyLabel,
                                             (__bridge id)kSecValueRef: (__bridge id)publicKey
                                             }, nil);

    if (status != errSecSuccess) {
      CFRelease(privateKey);
      CFRelease(publicKey);
      *error = makeError(status, nil);
      return nil;
    }
  }

  NSData *data = [self getPublicKeyDataByLabel:pubKeyLabel];
  NSString* base64str = [data base64EncodedStringWithOptions:0];

  sacObject = SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                              kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                              0, &sacErr);

  status = SecItemAdd((__bridge CFDictionaryRef)@{
                                    (__bridge id)kSecAttrAccessControl: (__bridge_transfer id)sacObject,
                                    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                    (__bridge id)kSecAttrService: serviceID,
                                    (__bridge id)kSecAttrAccount:base64str,
                                    (__bridge id)kSecAttrGeneric:uuid,
                                    }, nil);

  if (status != errSecSuccess) {
    CFRelease(privateKey);
    CFRelease(publicKey);
    *error = makeError(status, nil);
    return nil;
  }


  status = [self tagKeyWithLabel:pubKeyLabel tag:[self toPublicIdentifier:base64str]];

  CFRelease(privateKey);
  CFRelease(publicKey);
  if (status != errSecSuccess) {
    *error = makeError(status, nil);
    return nil;
  }

  return base64str;
}

RCT_EXPORT_METHOD(sign:(nonnull NSString *)serviceID
                  pub:(nonnull NSString *)base64pub
                  hash:(nonnull NSString *)base64Hash
                  //                  withAuthenticationPrompt:(NSString *)prompt
                  callback:(RCTResponseSenderBlock)callback) {
  // Query private key object from the keychain.
  NSData *hash = [[NSData alloc] initWithBase64EncodedString:base64Hash options:0];
  if ([hash length] != HASH_LENGTH) {
    NSString* message = [NSString stringWithFormat:@"hash parameter must be %d bytes", HASH_LENGTH];
    callback(@[badParamError(message)]);
    return;
  }

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary* error;
    NSData* sig = [self sign:serviceID pub:base64pub hash:hash error:&error];
    if (!sig) {
      callback(@[error]);
      return;
    }

    NSString* base64sig = [sig base64EncodedStringWithOptions:0];
    callback(@[[NSNull null], base64sig]);
  });
}

-(NSData *)sign:(nonnull NSString *)serviceID
            pub:(nonnull NSString *)base64pub
           hash:(nonnull NSData *)hash
          error:(NSDictionary **) error {

  SecKeyRef privateKey = [self getPrivateKeyRef:serviceID pub:base64pub];
  if (!privateKey) {
    *error = makeError(errSecItemNotFound, nil);
    return nil;
  }

  // Sign the data in the digest/digestLength memory block.
  uint8_t signature[128];
  size_t signatureLength = sizeof(signature);
  OSStatus status = SecKeyRawSign(
                         privateKey,
                         kTypeOfSigPadding,
                         (const uint8_t*)[hash bytes],
                         HASH_LENGTH,
                         signature,
                         &signatureLength);

  CFRelease(privateKey);
  if (status != errSecSuccess) {
    *error = makeError(status, nil);
    return nil;
  }

//  NSError* vError;
  NSData* sigData = [NSData dataWithBytes:(const void *)signature length:signatureLength];
//  BOOL verified = [self verify:base64pub hash:hash sig:sigData error:&vError];
//  if (!verified) {
//    NSLog(@"uh oh, failed to verify sig");
//  }

  return sigData;
}

RCT_EXPORT_METHOD(verify:(NSString *)base64pub
                  hash:(NSString *)base64Hash
                  sig:(NSString *)sig
             callback:(RCTResponseSenderBlock)callback) {

  NSData *hash = [[NSData alloc] initWithBase64EncodedString:base64Hash options:0];
  if ([hash length] != HASH_LENGTH) {
    NSString* message = [NSString stringWithFormat:@"hash parameter must be %d bytes", HASH_LENGTH];
    callback(@[badParamError(message)]);
    return;
  }

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSData* sigData = [[NSData alloc] initWithBase64EncodedString:sig options:0];
    NSDictionary* error = nil;
    BOOL verified = [self verify:base64pub hash:hash sig:sigData error:&error];
    if (!verified) {
      callback(@[error, @NO]);
      return;
    }

    callback(@[[NSNull null], @YES]);
  });
}

-(BOOL) verify:(NSString *)base64pub
          hash:(NSData *)hash
           sig:(NSData *)sig
         error:(NSDictionary **)error {

  SecKeyRef publicKey = [self getPublicKeyRef:[self toPublicIdentifier:base64pub]];
  if (!publicKey) {
    *error = makeError(errSecItemNotFound, nil);
    return false;
  }

  OSStatus status = SecKeyRawVerify(
                                publicKey,
                                kTypeOfSigPadding,
                                (const uint8_t *)[hash bytes],
                                HASH_LENGTH,
                                (const uint8_t *)[sig bytes],
                                [sig length]
                                );

  if (status != errSecSuccess) {
    *error = makeError(status, nil);
    return false;
  }

  return true;
}

-(OSStatus) tagKeyWithLabel:(NSString*)label tag:(NSString*)tag
{
  SecKeyRef foundItem;// = [self getKeyRefByLabel:label];
  OSStatus findStatus = SecItemCopyMatching((__bridge CFDictionaryRef)@{
                                                                        (__bridge id)kSecClass: (__bridge id)kSecClassKey,
                                                                        (__bridge id)kSecAttrApplicationLabel: label,
                                                                        (__bridge id)kSecReturnAttributes: @YES,
                                                                        }, (CFTypeRef *)&foundItem);

  if (findStatus != errSecSuccess) {
    NSLog(@"failed to find key: %d", findStatus);
    return findStatus;
  }

  NSMutableDictionary *updateDict = (__bridge NSMutableDictionary *)foundItem;
  [updateDict setObject:tag forKey:(__bridge id)kSecAttrApplicationTag];
  [updateDict removeObjectForKey:(__bridge id)kSecClass];
  OSStatus updateStatus = SecItemUpdate((__bridge CFDictionaryRef)@{
                                                                    (__bridge id)kSecClass: (__bridge id)kSecClassKey,
                                                                    (__bridge id)kSecAttrApplicationLabel: label,
                                                                    }, (__bridge CFDictionaryRef)updateDict);

  if (updateStatus != errSecSuccess) {
    NSLog(@"failed to update key: %d", updateStatus);
    return updateStatus;
  }

  OSStatus check = SecItemCopyMatching((__bridge CFDictionaryRef)@{
                                                                   (__bridge id)kSecClass: (__bridge id)kSecClassKey,
                                                                   (__bridge id)kSecAttrApplicationTag: tag,
                                                                   (__bridge id)kSecReturnAttributes: @YES,
                                                                   }, (CFTypeRef *)&foundItem);

  if (check != errSecSuccess) {
    NSLog(@"failed to retrieve key based on new attributes: %d", check);
  }

  return check;
}

- (NSString *) toPublicIdentifier:(NSString *)privIdentifier
{
  return [privIdentifier stringByAppendingString:@"-pub"];
}

- (NSString *) toUUIDIdentifier:(NSString *)privIdentifier
{
  return [privIdentifier stringByAppendingString:@"-uuid"];
}

NSDictionary* toRCTError(NSError* error)
{
  return RCTMakeAndLogError([error description], nil, [error dictionaryWithValuesForKeys:@[@"domain", @"code"]]);
}

NSDictionary * makeError(OSStatus status, NSString* msg)
{
  if (msg == nil) msg = keychainStatusToString(status);
  NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:@{ @"description": msg }];
  return toRCTError(error);
}

NSError *badParamError(NSString *errMsg)
{
  return [NSError errorWithDomain:RNECCErrorDomain code:RNECCBadParamError userInfo:@{ @"description": errMsg }];
}

-(NSData *)getPublicKeyDataByLabel:(NSString *)label
{

  NSDictionary* keyAttrs = @{
                             (__bridge id)kSecClass: (__bridge id)kSecClassKey,
                             (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
                             (__bridge id)kSecAttrApplicationLabel: label,
                             (__bridge id)kSecReturnData: @YES,
                             };

  CFTypeRef result;
  OSStatus sanityCheck = SecItemCopyMatching((__bridge CFDictionaryRef)keyAttrs, &result);

  if (sanityCheck != noErr)
  {
    return nil;
  }

  return CFBridgingRelease(result);
}

-(SecKeyRef)getKeyRefByLabel:(NSString *)label
{
  SecKeyRef keyRef;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)@{
    (__bridge id)kSecClass: (__bridge id)kSecClassKey,
    (__bridge id)kSecReturnRef: @YES,
    (__bridge id)kSecAttrApplicationLabel:label
  }, (CFTypeRef *)&keyRef);

  if (status != errSecSuccess)
  {
    return nil;
  }

  return keyRef;
}

-(SecKeyRef)getPrivateKeyRef:(NSString *)serviceID
                         pub:(NSString *)base64pub
{
  NSDictionary* uuidAttrs = @{
                             (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                             (__bridge id)kSecAttrService: serviceID,
                             (__bridge id)kSecAttrAccount:base64pub,
                             (__bridge id)kSecReturnAttributes: @YES,
                             };

  NSDictionary* found = nil;
  CFTypeRef foundTypeRef = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef) uuidAttrs, (CFTypeRef*)&foundTypeRef);

  if (status != errSecSuccess) {
    return nil;
  }

  found = (__bridge NSDictionary*)(foundTypeRef);
  NSString* uuid = [found objectForKey:(__bridge id)(kSecAttrGeneric)];
  return [self getKeyRefByLabel:uuid];
}

-(SecKeyRef)getPublicKeyRef:(NSString *)base64pub
{
  NSDictionary* keyAttrs = @{
                              (__bridge id)kSecClass: (__bridge id)kSecClassKey,
                              (__bridge id)kSecReturnRef: @YES,
                              (__bridge id)kSecAttrApplicationTag: base64pub
                              };

  SecKeyRef keyRef;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)keyAttrs, (CFTypeRef *)&keyRef);
  if (status != errSecSuccess)
  {
    return nil;
  }

  return keyRef;
}

- (NSString *)uuidString {
  CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
  NSString *uuidString = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
  CFRelease(uuid);

  return uuidString;
}

NSString *keychainStatusToString(OSStatus status) {
  NSString *message = [NSString stringWithFormat:@"%ld", (long)status];

  switch (status) {
    case errSecSuccess:
      message = @"success";
      break;

    case errSecDuplicateItem:
      message = @"error item already exists";
      break;

    case errSecItemNotFound :
      message = @"error item not found";
      break;

    case errSecAuthFailed:
      message = @"error item authentication failed";
      break;

    default:
      break;
  }

  return message;
}

@end

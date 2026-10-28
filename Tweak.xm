#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <Security/Security.h>

static NSString *const kIGSEDirName = @"IGSession";
static NSString *const kIGSEGenerator = @"IGSessionExtractor";

static NSMutableDictionary<NSString *, NSString *> *s_headers;
static NSMutableDictionary<NSString *, NSString *> *s_extraCookies;
static NSDictionary *s_authorizationData;
static NSString *s_activeUserID;
static NSString *s_mid;
static NSString *s_deviceID;
static NSString *s_clientSessionID;
static NSString *s_wwwClaim;
static NSObject *s_lock;
static BOOL s_dumping;
static NSTimeInterval s_lastDump;

static void IGSELog(NSString *message);

static BOOL IGSEIsInstagramURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    return [host hasSuffix:@"instagram.com"] || [host hasSuffix:@"cdninstagram.com"];
}

static BOOL IGSEWantedHeader(NSString *key) {
    if ([key isEqualToString:@"authorization"] || [key isEqualToString:@"cookie"] ||
        [key isEqualToString:@"user-agent"] || [key isEqualToString:@"accept-language"] ||
        [key isEqualToString:@"x-mid"] || [key isEqualToString:@"ig-intended-user-id"]) {
        return YES;
    }
    return [key hasPrefix:@"x-ig-"] || [key hasPrefix:@"ig-u-"] ||
           [key hasPrefix:@"x-bloks-"] || [key hasPrefix:@"x-pigeon-"] ||
           [key hasPrefix:@"x-fb-"] || [key hasPrefix:@"x-zero-"];
}

static NSDictionary *IGSEParseAuthorization(NSString *value) {
    if (![value hasPrefix:@"Bearer IGT:2:"]) return nil;
    NSString *raw = [value substringFromIndex:13];
    NSMutableString *base64 = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=' ||
                  c == '-' || c == '_';
        if (!ok) break;
        [base64 appendFormat:@"%C", (unichar)(c == '-' ? '+' : (c == '_' ? '/' : c))];
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (data.length == 0) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static void IGSEMergeCookieHeader(NSString *value) {
    for (NSString *pair in [value componentsSeparatedByString:@";"]) {
        NSRange equals = [pair rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *name = [[pair substringToIndex:equals.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *cookieValue = [[pair substringFromIndex:equals.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (name.length && cookieValue.length) s_extraCookies[name] = cookieValue;
    }
}

static void IGSECaptureCookie(NSHTTPCookie *cookie) {
    if (![cookie.domain.lowercaseString containsString:@"instagram.com"]) return;
    if (cookie.name.length == 0 || cookie.value.length == 0) return;
    @synchronized(s_lock) {
        s_extraCookies[cookie.name] = cookie.value;
    }
}

static void IGSECaptureCookieArray(NSArray<NSHTTPCookie *> *cookies) {
    for (NSHTTPCookie *cookie in cookies) IGSECaptureCookie(cookie);
}

static void IGSECaptureHeader(NSString *field, NSString *value, NSURL *url) {
    if (field.length == 0 || value.length == 0 || !IGSEIsInstagramURL(url)) return;
    NSString *key = field.lowercaseString;
    if (!IGSEWantedHeader(key)) return;
    @synchronized(s_lock) {
        if ([key isEqualToString:@"authorization"]) {
            NSDictionary *parsed = IGSEParseAuthorization(value);
            if (parsed) {
                s_authorizationData = parsed;
                IGSELog(@"authorization captured");
            }
        } else if ([key isEqualToString:@"cookie"]) {
            IGSEMergeCookieHeader(value);
        } else {
            s_headers[key] = value;
        }
    }
}

static void IGSECaptureRequest(NSURLRequest *request) {
    if (!IGSEIsInstagramURL(request.URL)) return;
    [request.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        IGSECaptureHeader(key, value, request.URL);
    }];
}

static NSString *IGSEHeader(NSString *key) {
    @synchronized(s_lock) {
        return s_headers[key];
    }
}

static NSString *IGSEUUID(void) {
    return NSUUID.UUID.UUIDString.lowercaseString;
}

static NSString *IGSEAndroidID(void) {
    NSString *uuid = [IGSEUUID() stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return [@"android-" stringByAppendingString:[uuid substringToIndex:16]];
}

static NSString *IGSEUsernameFromValue(id value) {
    if ([value isKindOfClass:NSDictionary.class]) {
        id username = ((NSDictionary *)value)[@"username"];
        if ([username isKindOfClass:NSString.class] && [username length]) return username;
        for (NSString *key in @[@"user", @"currentUser", @"userInfo", @"account"]) {
            NSString *found = IGSEUsernameFromValue(((NSDictionary *)value)[key]);
            if (found.length) return found;
        }
        return nil;
    }
    if ([value isKindOfClass:NSArray.class]) {
        for (id child in (NSArray *)value) {
            NSString *found = IGSEUsernameFromValue(child);
            if (found.length) return found;
        }
        return nil;
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *text = value;
        if ([text hasPrefix:@"{"] || [text hasPrefix:@"["]) {
            NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
            id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (object) {
                NSString *found = IGSEUsernameFromValue(object);
                if (found.length) return found;
            }
        }
        NSRange marker = [text rangeOfString:@"\"username\":\""];
        if (marker.location != NSNotFound) {
            NSUInteger start = NSMaxRange(marker);
            NSRange rest = NSMakeRange(start, text.length - start);
            NSRange quote = [text rangeOfString:@"\"" options:0 range:rest];
            if (quote.location != NSNotFound) return [text substringWithRange:NSMakeRange(start, quote.location - start)];
        }
    }
    return nil;
}

static NSString *IGSEFindUsername(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *knownKeys = @[@"currentUser", @"lastLoggedInUser", @"IGCurrentUser", @"user", @"currentUserJSON"];
    for (NSString *key in knownKeys) {
        NSString *found = IGSEUsernameFromValue([defaults objectForKey:key]);
        if (found.length) return found;
    }
    NSDictionary *all = [defaults dictionaryRepresentation];
    for (NSString *key in all) {
        NSString *lower = key.lowercaseString;
        if (![lower containsString:@"user"] && ![lower containsString:@"account"]) continue;
        NSString *found = IGSEUsernameFromValue(all[key]);
        if (found.length) return found;
    }
    return nil;
}

static NSDictionary *IGSECollectCookies(void) {
    NSMutableDictionary *cookies = [NSMutableDictionary dictionary];
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *urls = @[
        @"https://www.instagram.com/",
        @"https://i.instagram.com/",
        @"https://instagram.com/"
    ];
    for (NSString *urlString in urls) {
        NSURL *url = [NSURL URLWithString:urlString];
        for (NSHTTPCookie *cookie in [storage cookiesForURL:url]) {
            if (cookie.name.length && cookie.value.length) cookies[cookie.name] = cookie.value;
        }
    }
    NSArray *allCookies = storage.cookies;
    IGSELog([NSString stringWithFormat:@"storage cookies=%lu", (unsigned long)allCookies.count]);
    for (NSHTTPCookie *cookie in allCookies) {
        if (![cookie.domain.lowercaseString containsString:@"instagram.com"]) continue;
        IGSELog([NSString stringWithFormat:@"cookie %@ domain=%@ len=%lu",
                 cookie.name, cookie.domain, (unsigned long)cookie.value.length]);
        if (cookie.name.length && cookie.value.length) cookies[cookie.name] = cookie.value;
    }
    @synchronized(s_lock) {
        [cookies addEntriesFromDictionary:s_extraCookies];
        IGSELog([NSString stringWithFormat:@"captured cookies=%lu", (unsigned long)s_extraCookies.count]);
    }
    return cookies;
}

static NSString *IGSEUserIDFromSessionID(NSString *sessionID) {
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < sessionID.length; i++) {
        unichar c = [sessionID characterAtIndex:i];
        if (c < '0' || c > '9') break;
        [digits appendFormat:@"%C", c];
    }
    return digits.length ? digits : nil;
}

static NSString *IGSESafeName(NSString *name) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        [out appendFormat:@"%C", (unichar)([allowed characterIsMember:c] ? c : '_')];
    }
    return out.length ? out : @"unknown";
}

static void IGSEParseSessionFromText(NSString *text) {
    if (text.length == 0) return;
    NSRange marker = [text rangeOfString:@"sessionid"];
    if (marker.location == NSNotFound) return;
    NSUInteger index = NSMaxRange(marker);
    NSCharacterSet *skip = [NSCharacterSet characterSetWithCharactersInString:@"\"':= \\"];
    while (index < text.length && [skip characterIsMember:[text characterAtIndex:index]]) index++;
    NSMutableString *value = [NSMutableString string];
    while (index < text.length) {
        unichar c = [text characterAtIndex:index];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '%' || c == ':' || c == '-' || c == '_';
        if (!ok) break;
        [value appendFormat:@"%C", c];
        index++;
    }
    if (value.length > 30) {
        @synchronized(s_lock) {
            s_extraCookies[@"sessionid"] = value;
        }
        IGSELog([NSString stringWithFormat:@"sessionid from keychain len=%lu", (unsigned long)value.length]);
    }
}

static void IGSEParseAuthText(NSString *text, NSMutableDictionary *authByUser) {
    if (text.length == 0) return;
    NSRange bearer = [text rangeOfString:@"Bearer IGT:2:"];
    if (bearer.location != NSNotFound) {
        NSString *value = [text substringFromIndex:bearer.location];
        NSDictionary *auth = IGSEParseAuthorization(value);
        NSString *userID = auth[@"ds_user_id"];
        if (userID.length) authByUser[userID] = auth;
    }
    if ([text hasPrefix:@"{"]) {
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([object isKindOfClass:NSDictionary.class]) {
            for (id value in [object allValues]) {
                if ([value isKindOfClass:NSString.class]) IGSEParseAuthText(value, authByUser);
            }
        }
    }
}

static void IGSEScanKeychain(void) {
    NSDictionary *query = @{
        (__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
        (__bridge NSString *)kSecReturnAttributes: @YES,
        (__bridge NSString *)kSecReturnData: @YES,
        (__bridge NSString *)kSecMatchLimit: (__bridge NSString *)kSecMatchLimitAll
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == NULL) {
        IGSELog([NSString stringWithFormat:@"keychain scan status=%d", (int)status]);
        return;
    }
    NSArray *items = CFBridgingRelease(result);
    IGSELog([NSString stringWithFormat:@"keychain items=%lu", (unsigned long)items.count]);
    NSMutableDictionary *authByUser = [NSMutableDictionary dictionary];
    NSMutableDictionary *claimsByUser = [NSMutableDictionary dictionary];
    for (NSDictionary *item in items) {
        NSString *service = item[(__bridge NSString *)kSecAttrService];
        NSString *account = item[(__bridge NSString *)kSecAttrAccount];
        NSData *data = item[(__bridge NSString *)kSecValueData];
        NSString *lower = [NSString stringWithFormat:@"%@ %@", service ?: @"", account ?: @""].lowercaseString;
        if (![lower containsString:@"instagram"] && ![lower containsString:@"session"] &&
            ![lower containsString:@"burbn"]) {
            continue;
        }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        IGSELog([NSString stringWithFormat:@"keychain service=%@ account=%@ len=%lu text=%@",
                 service ?: @"", account ?: @"", (unsigned long)data.length,
                 text.length > 300 ? [text substringToIndex:300] : (text ?: @"")]);

        if ([lower containsString:@"last_logged_in_user_pk"] && text.length) {
            @synchronized(s_lock) { s_activeUserID = text; }
        }
        if ([lower containsString:@"activeaccount"] && account.length) {
            @synchronized(s_lock) { s_activeUserID = account; }
        }
        if ([lower containsString:@"mid"] && text.length) {
            @synchronized(s_lock) { s_mid = text; }
        }
        if (([lower containsString:@"deviceid"] || [lower containsString:@"unique_id"]) && text.length) {
            @synchronized(s_lock) { s_deviceID = text; }
        }
        if ([lower containsString:@"loggingclaims"] && text.length) {
            NSData *jsonData = [text dataUsingEncoding:NSUTF8StringEncoding];
            id object = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
            if ([object isKindOfClass:NSDictionary.class]) {
                [claimsByUser addEntriesFromDictionary:object];
            }
        }
        IGSEParseAuthText(text, authByUser);
        IGSEParseSessionFromText(text);
    }

    NSString *active = nil;
    @synchronized(s_lock) { active = s_activeUserID; }
    NSDictionary *chosenAuth = active ? authByUser[active] : authByUser.allValues.firstObject;
    if (chosenAuth) {
        @synchronized(s_lock) { s_authorizationData = chosenAuth; }
        IGSELog([NSString stringWithFormat:@"authorization from keychain user=%@", chosenAuth[@"ds_user_id"]]);
    }
    id claimValue = active ? claimsByUser[active] : claimsByUser.allValues.firstObject;
    NSString *claim = [claimValue isKindOfClass:NSString.class] ? claimValue : nil;
    if (claim.length) {
        @synchronized(s_lock) { s_wwwClaim = claim; }
    }
}

static void IGSEScanDefaults(void) {
    NSDictionary *all = [NSUserDefaults standardUserDefaults].dictionaryRepresentation;
    for (NSString *key in all) {
        NSString *lower = key.lowercaseString;
        if (![lower containsString:@"session"] && ![lower containsString:@"cookie"]) continue;
        id value = all[key];
        NSString *text = [value isKindOfClass:NSString.class] ? value : [value description];
        IGSELog([NSString stringWithFormat:@"defaults %@=%@", key,
                 text.length > 300 ? [text substringToIndex:300] : text]);
        if ([key isEqualToString:@"kFBPreviousAppSessionID"] || [key isEqualToString:@"session_id"]) {
            @synchronized(s_lock) { s_clientSessionID = text; }
        }
        IGSEParseSessionFromText(text);
    }
}

static NSDictionary *IGSEBuildSettings(void) {
    NSDictionary *authorization = nil;
    NSString *storedMid = nil;
    NSString *storedDeviceID = nil;
    NSString *storedClientSessionID = nil;
    NSString *storedClaim = nil;
    @synchronized(s_lock) {
        authorization = s_authorizationData;
        storedMid = s_mid;
        storedDeviceID = s_deviceID;
        storedClientSessionID = s_clientSessionID;
        storedClaim = s_wwwClaim;
    }

    IGSEScanKeychain();
    IGSEScanDefaults();
    NSMutableDictionary *cookies = [IGSECollectCookies() mutableCopy];
    NSString *sessionID = cookies[@"sessionid"];
    if (sessionID.length == 0) sessionID = authorization[@"sessionid"];
    if (sessionID.length == 0) return nil;
    cookies[@"sessionid"] = sessionID;

    NSString *userID = cookies[@"ds_user_id"];
    if (userID.length == 0) userID = authorization[@"ds_user_id"];
    if (userID.length == 0) userID = IGSEHeader(@"ig-u-ds-user-id");
    if (userID.length == 0) userID = IGSEHeader(@"ig-intended-user-id");
    if (userID.length == 0) userID = IGSEUserIDFromSessionID(sessionID);
    if (userID.length == 0) userID = @"unknown";

    NSMutableDictionary *auth = authorization ? [authorization mutableCopy] : [NSMutableDictionary dictionary];
    auth[@"ds_user_id"] = userID;
    auth[@"sessionid"] = sessionID;
    auth[@"should_use_header_over_cookies"] = @YES;

    NSString *locale = IGSEHeader(@"x-ig-app-locale") ?: IGSEHeader(@"x-ig-device-locale") ?: IGSEHeader(@"accept-language");
    locale = [[locale componentsSeparatedByString:@","] firstObject];
    locale = [locale stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    if (locale.length == 0) locale = @"en_US";

    NSString *country = IGSEHeader(@"x-ig-app-startup-country");
    if (country.length == 0) {
        NSArray *parts = [locale componentsSeparatedByString:@"_"];
        country = parts.count > 1 ? [parts[1] uppercaseString] : @"US";
    }

    NSInteger timezoneOffset = [IGSEHeader(@"x-ig-timezone-offset") integerValue];
    if (timezoneOffset == 0) timezoneOffset = NSTimeZone.localTimeZone.secondsFromGMT;

    NSMutableDictionary *uuids = [NSMutableDictionary dictionary];
    uuids[@"uuid"] = IGSEHeader(@"x-ig-device-id") ?: storedDeviceID ?: IGSEUUID();
    uuids[@"phone_id"] = IGSEHeader(@"x-ig-family-device-id") ?: IGSEUUID();
    uuids[@"client_session_id"] = IGSEHeader(@"x-pigeon-session-id") ?: storedClientSessionID ?: IGSEUUID();
    uuids[@"android_device_id"] = IGSEHeader(@"x-ig-android-id") ?: IGSEAndroidID();
    uuids[@"advertising_id"] = IGSEUUID();
    uuids[@"request_id"] = IGSEUUID();
    uuids[@"tray_session_id"] = IGSEUUID();

    NSString *username = IGSEFindUsername();
    NSString *userAgent = IGSEHeader(@"user-agent");

    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    settings[@"cookies"] = cookies;
    settings[@"authorization_data"] = auth;
    settings[@"uuids"] = uuids;
    settings[@"mid"] = cookies[@"mid"] ?: IGSEHeader(@"x-mid") ?: storedMid ?: @"";
    settings[@"ig_u_rur"] = IGSEHeader(@"ig-u-rur") ?: cookies[@"rur"] ?: @"";
    settings[@"ig_www_claim"] = IGSEHeader(@"x-ig-www-claim") ?: storedClaim ?: @"";
    settings[@"locale"] = locale;
    settings[@"country"] = country.uppercaseString;
    settings[@"country_code"] = @1;
    settings[@"timezone_offset"] = @(timezoneOffset);
    settings[@"timezone_name"] = NSTimeZone.localTimeZone.name ?: @"";
    settings[@"push_disabled"] = @YES;
    settings[@"last_login"] = @([[NSDate date] timeIntervalSince1970]);
    if (userAgent.length) settings[@"user_agent"] = userAgent;

    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    meta[@"generator"] = kIGSEGenerator;
    meta[@"captured_at"] = @([[NSDate date] timeIntervalSince1970]);
    meta[@"user_id"] = userID;
    if (username.length) meta[@"username"] = username;
    if (IGSEHeader(@"x-ig-app-version").length) meta[@"app_version"] = IGSEHeader(@"x-ig-app-version");
    settings[@"_meta"] = meta;

    return settings;
}

static NSString *IGSEDocumentsDirectory(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kIGSEDirName];
}

static NSString *IGSEWriteData(NSData *data, NSString *filename) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *directories = @[
        [@"/var/jb/var/mobile/Documents" stringByAppendingPathComponent:kIGSEDirName],
        [@"/var/jb/var/mobile/Library/Preferences" stringByAppendingPathComponent:kIGSEDirName],
        [@"/var/mobile/Documents" stringByAppendingPathComponent:kIGSEDirName],
        [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:kIGSEDirName],
        IGSEDocumentsDirectory()
    ];
    NSString *firstPath = nil;
    for (NSString *directory in directories) {
        [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [directory stringByAppendingPathComponent:filename];
        NSError *error = nil;
        if ([data writeToFile:path options:NSDataWritingAtomic error:&error]) {
            [manager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
            if (!firstPath) firstPath = path;
        } else {
            IGSELog([NSString stringWithFormat:@"write fail %@: %@", path, error.localizedDescription ?: @"?"]);
        }
    }
    return firstPath;
}

static void IGSELog(NSString *message) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *directories = @[
        IGSEDocumentsDirectory(),
        [@"/var/jb/var/mobile/Documents" stringByAppendingPathComponent:kIGSEDirName],
        [@"/var/mobile/Documents" stringByAppendingPathComponent:kIGSEDirName]
    ];
    for (NSString *directory in directories) {
        [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [directory stringByAppendingPathComponent:@"IGSessionExtractor.log"];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } else {
            [data writeToFile:path atomically:NO];
        }
    }
}

static void IGSEAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = UIApplication.sharedApplication.keyWindow;
        if (!window) {
            for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
        }
        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController) controller = controller.presentedViewController;
        if (!controller) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
}

static void IGSEShareFile(NSString *path) {
    if (path.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = UIApplication.sharedApplication.keyWindow;
        if (!window) {
            for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
        }
        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController) controller = controller.presentedViewController;
        if (!controller) return;
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:path]]
            applicationActivities:nil];
        if (share.popoverPresentationController) {
            share.popoverPresentationController.sourceView = controller.view;
            share.popoverPresentationController.sourceRect = CGRectMake(
                CGRectGetMidX(controller.view.bounds),
                CGRectGetMidY(controller.view.bounds), 1, 1);
        }
        [controller presentViewController:share animated:YES completion:nil];
    });
}

static void IGSEDump(BOOL showAlert) {
    @synchronized(s_lock) {
        if (s_dumping) {
            IGSELog(@"dump skip busy");
            return;
        }
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - s_lastDump < 3.0) {
            IGSELog(@"dump skip debounce");
            return;
        }
        s_dumping = YES;
    }

    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    task = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        if (task != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }
    }];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        IGSELog(@"dump start");
        NSDictionary *settings = IGSEBuildSettings();
        NSString *message = nil;
        NSString *jsonPath = nil;
        if (!settings) {
            IGSELog(@"no sessionid");
            message = @"Chưa có sessionid. Hãy đăng nhập Instagram trước.";
        } else {
            NSError *error = nil;
            NSData *json = [NSJSONSerialization dataWithJSONObject:settings
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&error];
            NSDictionary *meta = settings[@"_meta"];
            NSString *userID = meta[@"user_id"] ?: @"unknown";
            NSString *username = meta[@"username"] ?: userID;
            NSString *base = [NSString stringWithFormat:@"ig_%@_%@",
                              IGSESafeName(username), IGSESafeName(userID)];
            NSDictionary *cookies = settings[@"cookies"];
            NSData *sessionData = [cookies[@"sessionid"] dataUsingEncoding:NSUTF8StringEncoding];
            jsonPath = json ? IGSEWriteData(json, [base stringByAppendingString:@".json"]) : nil;
            NSString *sessionPath = IGSEWriteData(sessionData, [base stringByAppendingString:@".sessionid.txt"]);
            IGSELog([NSString stringWithFormat:@"cookies=%lu user=%@ id=%@ json=%@ session=%@",
                     (unsigned long)cookies.count, username, userID, jsonPath ?: @"(nil)", sessionPath ?: @"(nil)"]);
            if (jsonPath) {
                IGSEWriteData(json, @"latest.json");
                if (sessionPath) {
                    IGSEWriteData(sessionData, @"latest.sessionid.txt");
                }
                message = [NSString stringWithFormat:@"Đã lưu session:\n%@\n\nUser: %@ (%@)", jsonPath, username, userID];
            } else {
                message = @"Không ghi được file. Kiểm tra quyền truy cập.";
            }
        }

        @synchronized(s_lock) {
            s_lastDump = [NSDate date].timeIntervalSince1970;
            s_dumping = NO;
        }
        if (task != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }
        if (showAlert) {
            if (jsonPath) {
                IGSEShareFile(jsonPath);
            } else {
                IGSEAlert(@"IGSessionExtractor", message);
            }
        }
    });
}

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    IGSECaptureHeader(field, value, self.URL);
    %orig;
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    IGSECaptureHeader(field, value, self.URL);
    %orig;
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    IGSECaptureRequest(request);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    IGSECaptureRequest(request);
    return %orig;
}

%end

%hook NSURLConnection

- (instancetype)initWithRequest:(NSURLRequest *)request delegate:(id)delegate startImmediately:(BOOL)startImmediately {
    IGSECaptureRequest(request);
    return %orig;
}

%end

%hook NSHTTPCookieStorage

- (NSArray<NSHTTPCookie *> *)cookies {
    NSArray *cookies = %orig;
    IGSECaptureCookieArray(cookies);
    return cookies;
}

- (NSArray<NSHTTPCookie *> *)cookiesForURL:(NSURL *)URL {
    NSArray *cookies = %orig;
    IGSECaptureCookieArray(cookies);
    return cookies;
}

+ (NSHTTPCookieStorage *)sharedCookieStorageForGroupContainerIdentifier:(NSString *)identifier {
    IGSELog([NSString stringWithFormat:@"cookie storage group=%@", identifier]);
    return %orig;
}

- (void)setCookie:(NSHTTPCookie *)cookie {
    %orig;
    IGSECaptureCookie(cookie);
    if ([cookie.domain.lowercaseString containsString:@"instagram.com"] &&
        [cookie.name isEqualToString:@"sessionid"]) {
        IGSEDump(NO);
    }
}

- (void)setCookies:(NSArray<NSHTTPCookie *> *)cookies
            forURL:(NSURL *)URL
  mainDocumentURL:(NSURL *)mainDocumentURL {
    %orig;
    IGSECaptureCookieArray(cookies);
    for (NSHTTPCookie *cookie in cookies) {
        if ([cookie.name isEqualToString:@"sessionid"] &&
            [cookie.domain.lowercaseString containsString:@"instagram.com"]) {
            IGSEDump(NO);
            break;
        }
    }
}

%end

%hook NSHTTPCookie

+ (instancetype)cookieWithProperties:(NSDictionary<NSHTTPCookiePropertyKey, id> *)properties {
    id cookie = %orig;
    if ([cookie isKindOfClass:NSHTTPCookie.class]) IGSECaptureCookie(cookie);
    return cookie;
}

%end

%hook UIWindow

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) IGSEDump(YES);
    %orig;
}

%end

%ctor {
    s_headers = [NSMutableDictionary dictionary];
    s_extraCookies = [NSMutableDictionary dictionary];
    s_lock = [NSObject new];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
        IGSEDump(NO);
    }];
    [center addObserverForName:UIApplicationWillTerminateNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
        IGSEDump(NO);
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            IGSEDump(NO);
        });
    }];

    IGSELog([NSString stringWithFormat:@"loaded bundle=%@ process=%@",
             NSBundle.mainBundle.bundleIdentifier ?: @"(nil)",
             NSProcessInfo.processInfo.processName ?: @"(nil)"]);
    NSLog(@"[IGSessionExtractor] loaded");
}

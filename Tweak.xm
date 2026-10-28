#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>

static NSString *const kIGSEDirName = @"IGSession";
static NSString *const kIGSEGenerator = @"IGSessionExtractor";

static NSMutableDictionary<NSString *, NSString *> *s_headers;
static NSMutableDictionary<NSString *, NSString *> *s_extraCookies;
static NSDictionary *s_authorizationData;
static NSObject *s_lock;
static BOOL s_dumping;
static NSTimeInterval s_lastDump;

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
    NSString *base64 = [value substringFromIndex:13];
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

static void IGSECaptureHeader(NSString *field, NSString *value, NSURL *url) {
    if (field.length == 0 || value.length == 0 || !IGSEIsInstagramURL(url)) return;
    NSString *key = field.lowercaseString;
    if (!IGSEWantedHeader(key)) return;
    @synchronized(s_lock) {
        if ([key isEqualToString:@"authorization"]) {
            NSDictionary *parsed = IGSEParseAuthorization(value);
            if (parsed) s_authorizationData = parsed;
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
    for (NSHTTPCookie *cookie in storage.cookies) {
        if (![cookie.domain.lowercaseString containsString:@"instagram.com"]) continue;
        if (cookie.name.length && cookie.value.length) cookies[cookie.name] = cookie.value;
    }
    @synchronized(s_lock) {
        [cookies addEntriesFromDictionary:s_extraCookies];
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
        [out appendFormat:@"%C", [allowed characterIsMember:c] ? c : '_'];
    }
    return out.length ? out : @"unknown";
}

static NSDictionary *IGSEBuildSettings(void) {
    NSDictionary *authorization = nil;
    @synchronized(s_lock) {
        authorization = s_authorizationData;
    }

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
    uuids[@"uuid"] = IGSEHeader(@"x-ig-device-id") ?: IGSEUUID();
    uuids[@"phone_id"] = IGSEHeader(@"x-ig-family-device-id") ?: IGSEUUID();
    uuids[@"client_session_id"] = IGSEHeader(@"x-pigeon-session-id") ?: IGSEUUID();
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
    settings[@"mid"] = cookies[@"mid"] ?: IGSEHeader(@"x-mid") ?: @"";
    settings[@"ig_u_rur"] = IGSEHeader(@"ig-u-rur") ?: cookies[@"rur"] ?: @"";
    settings[@"ig_www_claim"] = IGSEHeader(@"x-ig-www-claim") ?: @"";
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
        }
    }
    return firstPath;
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

static void IGSEDump(BOOL showAlert) {
    @synchronized(s_lock) {
        if (s_dumping) return;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - s_lastDump < 3.0) return;
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
        NSDictionary *settings = IGSEBuildSettings();
        NSString *message = nil;
        if (!settings) {
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
            NSString *jsonPath = json ? IGSEWriteData(json, [base stringByAppendingString:@".json"]) : nil;
            NSString *sessionPath = IGSEWriteData(sessionData, [base stringByAppendingString:@".sessionid.txt"]);
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
        if (showAlert) IGSEAlert(@"IGSessionExtractor", message);
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

- (void)setCookie:(NSHTTPCookie *)cookie {
    %orig;
    if ([cookie.domain.lowercaseString containsString:@"instagram.com"] &&
        [cookie.name isEqualToString:@"sessionid"]) {
        IGSEDump(NO);
    }
}

- (void)setCookies:(NSArray<NSHTTPCookie *> *)cookies
            forURL:(NSURL *)URL
  mainDocumentURL:(NSURL *)mainDocumentURL {
    %orig;
    for (NSHTTPCookie *cookie in cookies) {
        if ([cookie.name isEqualToString:@"sessionid"] &&
            [cookie.domain.lowercaseString containsString:@"instagram.com"]) {
            IGSEDump(NO);
            break;
        }
    }
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

    NSLog(@"[IGSessionExtractor] loaded");
}

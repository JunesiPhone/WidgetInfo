#import <objc/runtime.h>
#import <CoreLocation/CoreLocation.h>
#import <EventKit/EventKit.h>
#include <mach/mach.h>
#import <mach/mach_host.h>
#include <sys/sysctl.h>
#import "headers.h"
#import "substrate.h"
#import "weather.h"


static MPUNowPlayingController *globalMPUNowPlaying;
static NSMutableArray *_widgets = [NSMutableArray array];
static bool isOnSB;
static bool firstLoad = false;
static int lastCalledTouch = 1;
static int lastWeatherUpdate = 1;

// @interface EKReminder (more)
// - (id)dueDate;
// @end
/*
	All updates go through here. Easy to stop from always updating.
*/
static void update(NSString* values, NSString* type){
	for (UIWebView* widget in _widgets) {
		if([widget respondsToSelector:@selector(stringByEvaluatingJavaScriptFromString:)]){
			[widget stringByEvaluatingJavaScriptFromString:values];
			NSString* function = [NSString stringWithFormat:@"mainUpdate('%@')", type];
			[widget stringByEvaluatingJavaScriptFromString:function];
		}
	}
}

/*
	iOS10 changed temp type. What a mess. This will convert C or F
	depending on what the user has selected in the weather.app
*/
static int getIntFromWFTemp(WFTemperature* temp, City *city){
	if([[[UIDevice currentDevice] systemVersion] floatValue] >= 10.0f){
        return [[objc_getClass("WeatherPreferences") sharedPreferences] isCelsius] ? (int)temp.celsius : (int)temp.fahrenheit;
    }else{
        NSString *tempInt =  [NSString stringWithFormat:@"%@", temp];
        int temp = (int)[tempInt integerValue];
        if (![[objc_getClass("WeatherPreferences") sharedPreferences] isCelsius]){
            temp = ((temp * 9)/5) + 32;
        }
        return temp;
    }
}

//credit Andrew Wiik & Matchstic
//https://github.com/Matchstic/InfoStats2/blob/cd31d7a9ec266afb10ea3576b06399f5900c2c1e/InfoStats2/IS2Weather.m
static NSString* nameForCondition(int condition){
	MSImageRef weather = MSGetImageByName("/System/Library/PrivateFrameworks/Weather.framework/Weather");
    CFStringRef *_weatherDescription = (CFStringRef*)MSFindSymbol(weather, "_WeatherDescription") + condition;
    NSString *cond = (__bridge id)*_weatherDescription;
    return [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/Weather.framework"] localizedStringForKey:cond value:@"" table:@"WeatherFrameworkLocalizableStrings"];
}
//end


static void sendWeather(City* city){
	firstLoad = true;
	NSMutableDictionary *weatherInfo =[[NSMutableDictionary alloc] init];
	int temp = getIntFromWFTemp([city valueForKey:@"temperature"], city);
	int feelslike = getIntFromWFTemp([city valueForKey:@"feelsLike"], city);
	NSString *conditionString = nameForCondition(city.conditionCode);
	NSString *naturalCondition;

	if ([city respondsToSelector:@selector(naturalLanguageDescription)]) {
        naturalCondition = [city naturalLanguageDescription];
        NSMutableString *s = [NSMutableString stringWithString:naturalCondition];
        [s replaceOccurrencesOfString:@"\'" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [s length])];
        [s replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [s length])];
        [s replaceOccurrencesOfString:@"/" withString:@"\\/" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [s length])];
        [s replaceOccurrencesOfString:@"\n" withString:@"\\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [s length])];
        [s replaceOccurrencesOfString:@"\b" withString:@"\\b" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [s length])];
        [s replaceOccurrencesOfString:@"\f" withString:@"\\f" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [s length])];
        [s replaceOccurrencesOfString:@"\r" withString:@"\\r" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [s length])];
        [s replaceOccurrencesOfString:@"\t" withString:@"\\t" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [s length])];
        naturalCondition = [NSString stringWithString:s];
    } else {
        naturalCondition = @"No condition";
    }


	 NSMutableDictionary *dayForecasts;
     NSMutableArray *fcastArray = [[NSMutableArray alloc] init];

    for (DayForecast *day in city.dayForecasts) {
        int lowForcast = getIntFromWFTemp([day valueForKey:@"low"], city);
        int highForecast = getIntFromWFTemp([day valueForKey:@"high"], city);
        NSString *icon = [NSString stringWithFormat:@"%llu",day.icon];
        dayForecasts = [[NSMutableDictionary alloc] init];
        [dayForecasts setValue:[NSNumber numberWithInt:lowForcast] forKey:@"low"];
        [dayForecasts setValue:[NSNumber numberWithInt:highForecast] forKey:@"high"];
        [dayForecasts setValue:[NSString stringWithFormat:@"%llu",day.dayNumber] forKey:@"dayNumber"];
        [dayForecasts setValue:[NSString stringWithFormat:@"%llu",day.dayOfWeek] forKey:@"dayOfWeek"];
        [dayForecasts setValue:icon forKey:@"icon"];
        [fcastArray addObject:dayForecasts];
    }


    [weatherInfo setValue:city.name forKey:@"city"];
	[weatherInfo setValue:[NSNumber numberWithInt:temp] forKey:@"temperature"];
	[weatherInfo setValue:[NSNumber numberWithInt:feelslike] forKey:@"feelsLike"];
	[weatherInfo setValue:conditionString forKey:@"condition"];
	[weatherInfo setValue:naturalCondition forKey:@"naturalCondition"];
	[weatherInfo setValue:fcastArray forKey:@"dayForecasts"];
	[weatherInfo setValue:city.locationID forKey:@"latlong"];
	[weatherInfo setValue:[NSString stringWithFormat:@"%llu",city.conditionCode] forKey:@"conditionCode"];
	[weatherInfo setValue:[NSString stringWithFormat:@"%@",city.updateTimeString] forKey:@"updateTimeString"];
    [weatherInfo setValue:[NSString stringWithFormat:@"%d",(int)roundf(city.humidity)] forKey:@"humidity"];
    [weatherInfo setValue:[NSString stringWithFormat:@"%d",(int)roundf(city.dewPoint)] forKey:@"dewPoint"];
    [weatherInfo setValue:[NSString stringWithFormat:@"%d",(int)roundf(city.windChill)] forKey:@"windChill"];
    [weatherInfo setValue:[NSNumber numberWithInt:feelslike] forKey:@"feelsLike"];
    [weatherInfo setValue:[NSString stringWithFormat:@"%d",(int)roundf(city.windDirection)] forKey:@"windDirection"];
    [weatherInfo setValue:[NSString stringWithFormat:@"%d",(int)roundf(city.windSpeed)] forKey:@"windSpeed"];
    [weatherInfo setValue:[NSString stringWithFormat:@"%d",(int)roundf(city.visibility)] forKey:@"visibility"];
    [weatherInfo setValue:[NSString stringWithFormat:@"%llu",city.sunsetTime] forKey:@"sunsetTime"];
    [weatherInfo setValue:[NSString stringWithFormat:@"%llu",city.sunriseTime] forKey:@"sunriseTime"];
    [weatherInfo setValue:[NSString stringWithFormat:@"%d", city.precipitationForecast] forKey:@"precipitationForecast"];

    if([[city hourlyForecasts] count] > 0){
    	HourlyForecast* precip = [city hourlyForecasts][0];
    	[weatherInfo setValue:[NSString stringWithFormat:@"%d", (int)roundf(precip.percentPrecipitation)] forKey:@"chanceofrain"];
    }

	NSData * dictData = [NSJSONSerialization dataWithJSONObject:weatherInfo options:0 error:nil];
    NSString * jsonObj = [[NSString alloc] initWithData:dictData encoding:NSUTF8StringEncoding];
    NSString* finalObj = [NSString stringWithFormat:@"var weather = JSON.parse('%@');", jsonObj];

    //too much extra code was needed to support low and high on multiple firmwares.
    //It was much easier to do it javascript side, reason for this.
    NSString* lowHiBS = [NSString stringWithFormat:@"weather.low = weather.dayForecasts[0].low; weather.high = weather.dayForecasts[0].high;"];
	update(finalObj, @"weather");
	update(lowHiBS, @"weather");
}

/*
	Have I mentioned my love hate relationship with the weather.framework?
	This seems to work if location services is on or off. If location services
	are off then there needs to be a city set in the weather.app
	I did want to get user coordinates without location services, but decided against it.
*/

static void refreshWeather(){
	City *currentCity = nil;
	if([[objc_getClass("WeatherPreferences") sharedPreferences]localWeatherCity]){
		currentCity = [[objc_getClass("WeatherPreferences") sharedPreferences]localWeatherCity];
	}else{
		if([[[objc_getClass("WeatherPreferences") sharedPreferences]loadSavedCities] count] > 0){
			currentCity = [[objc_getClass("WeatherPreferences") sharedPreferences]loadSavedCities][0];
		}
	}
	if(![CLLocationManager locationServicesEnabled] || [objc_getClass("CLLocationManager") authorizationStatusForBundleIdentifier:@"com.apple.weather"] == 2){
		City* testCity = nil;
		if([[[objc_getClass("WeatherPreferences") sharedPreferences]loadSavedCities] count] > 0){
			testCity = [[objc_getClass("WeatherPreferences") sharedPreferences]loadSavedCities][0];
			if([testCity.name isEqualToString:@"Local Weather"]){
				if([[[objc_getClass("WeatherPreferences") sharedPreferences]loadSavedCities] count] > 1){
					testCity = [[objc_getClass("WeatherPreferences") sharedPreferences]loadSavedCities][1];
				}
			}
			if([[[UIDevice currentDevice] systemVersion] floatValue] < 10.0f){
	            [[objc_getClass("TWCLocationUpdater") sharedLocationUpdater] updateWeatherForLocation:testCity.location city:testCity withCompletionHandler:^{
	            	sendWeather(testCity);
	            }];
	        }else{
	            [[objc_getClass("TWCLocationUpdater") sharedLocationUpdater] _updateWeatherForLocation:testCity.location city:testCity completionHandler:^{
	            	sendWeather(testCity);
	            }];
	        }
		}
	}else{
        if(!currentCity){
            currentCity = [[objc_getClass("WeatherPreferences") sharedPreferences]loadSavedCities][0];
        }
		WeatherLocationManager* WLM = [objc_getClass("WeatherLocationManager")sharedWeatherLocationManager];
        TWCLocationUpdater *TWCLU = [objc_getClass("TWCLocationUpdater") sharedLocationUpdater];

        CLLocationManager *CLM = [[CLLocationManager alloc] init];
        [WLM setDelegate:CLM];

        if([[[UIDevice currentDevice] systemVersion] floatValue] > 8.3f){
        	[WLM setLocationTrackingReady:YES activelyTracking:NO watchKitExtension:NO];
        }

        [WLM setLocationTrackingActive:YES];
        [[objc_getClass("WeatherPreferences") sharedPreferences] setLocalWeatherEnabled:YES];

        if([[[UIDevice currentDevice] systemVersion] floatValue] < 10.0f){
            [TWCLU updateWeatherForLocation:[WLM location] city:currentCity];
            dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 0.2);
			dispatch_after(delay, dispatch_get_main_queue(), ^(void){
            	sendWeather(currentCity);
            });
        }else{
            [TWCLU _updateWeatherForLocation:[WLM location] city:currentCity completionHandler:^{
                sendWeather(currentCity);
            }];
        }
        [WLM setLocationTrackingActive:NO];
        [WLM setLocationTrackingIsReady:NO];
        [CLM release];
        WLM = nil;
        TWCLU = nil;
	}
	currentCity = nil;
}

/*
	well. this is what I ended up with. I needed some way of stopping the update for a period of time.
	This was the most reliable throughout the things I tired.
*/
static void getWeather(){
	if(lastWeatherUpdate > 0){
		lastWeatherUpdate = 0;
		dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 1200.0);
		dispatch_after(delay, dispatch_get_main_queue(), ^(void){
			lastWeatherUpdate = 1;
		});
		refreshWeather();
	}
}

//credit Matchstic
//https://github.com/Matchstic/InfoStats2/blob/cd31d7a9ec266afb10ea3576b06399f5900c2c1e/InfoStats2/IS2System.m
static int getSysInfo(uint typeSpecifier){
	size_t size = sizeof(int);
    int results;
    int mib[2] = {CTL_HW, typeSpecifier};
    sysctl(mib, 2, &results, &size, NULL, 0);
    return (int) results;
}
static int ramDataForType(int type){
	mach_port_t host_port;
    mach_msg_type_number_t host_size;
    vm_size_t pagesize;

    host_port = mach_host_self();
    host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
    host_page_size(host_port, &pagesize);

    vm_statistics_data_t vm_stat;

    if (host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size) != KERN_SUCCESS)
        NSLog(@"Failed to fetch vm statistics");

    /* Stats in bytes */
    NSUInteger giga = 1024*1024;

    if (type == 0) {
        return (int)getSysInfo(HW_USERMEM) / giga;
    } else if (type == -1) {
        return (int)getSysInfo(HW_PHYSMEM) / giga;
    }

    natural_t wired = vm_stat.wire_count * (natural_t)pagesize / (1024 * 1024);
    natural_t active = vm_stat.active_count * (natural_t)pagesize / (1024 * 1024);
    natural_t inactive = vm_stat.inactive_count * (natural_t)pagesize / (1024 * 1024);
    if (type == 1) {
        return vm_stat.free_count * (natural_t)pagesize / (1024 * 1024) + inactive; // Inactive is treated as free by iOS
    } else {
        return active + wired;
    }
}
//end

static void getEvents(){
    EKEventStore *store = nil;

    if(!store){
        store = [[EKEventStore alloc] init];
    }

     NSDate *start = [NSDate date];
     NSDate *end = [NSDate dateWithTimeInterval:25920000 sinceDate:start];


     NSPredicate* predicate = [store predicateForEventsWithStartDate:start endDate:end calendars:nil];
     NSArray *events = [store eventsMatchingPredicate:predicate];

     NSMutableDictionary *dateDict;
     NSMutableArray *dateDictArray = [[NSMutableArray alloc] init];
     NSString *dupeCatch = @"";

    for (EKEvent *object in events) {
        NSString* info = [NSString stringWithFormat:@"%@", object.title];
        NSCharacterSet *cs = [NSCharacterSet characterSetWithCharactersInString:@"!~`@#$%^&*-+();:=_{}[],.<>?\\/|\"\'"];

        NSString *filtered = [[info componentsSeparatedByCharactersInSet:cs] componentsJoinedByString:@""];
        NSMutableString *finalString = [NSMutableString stringWithString:filtered];
        [finalString replaceOccurrencesOfString:@"gmail" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [finalString length])];
        [finalString replaceOccurrencesOfString:@"coms" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [finalString length])];
        [finalString replaceOccurrencesOfString:@"yahoo" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [finalString length])];
        [finalString replaceOccurrencesOfString:@"couk" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [finalString length])];
        filtered = [NSString stringWithString:finalString];

        if (!([dupeCatch rangeOfString:filtered].location == NSNotFound)) {
            dateDict = [[NSMutableDictionary alloc]init];
            NSDateFormatter *dateFormat = [[NSDateFormatter alloc] init];
            [dateFormat setDateFormat:@"MM-dd-YYYY"];
            NSString* date = [dateFormat stringFromDate:object.startDate];

            date = [date stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
            date = [date stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
            date = [date stringByReplacingOccurrencesOfString:@"\'" withString:@"\\\'"];
            date = [date stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
            date = [date stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
            date = [date stringByReplacingOccurrencesOfString:@"\f" withString:@"\\f"];

            [dateDict setValue:date forKey:@"date"];

            [dateDict setValue:filtered forKey:@"title"];
            [dateDictArray addObject:dateDict];
        }
        dupeCatch = [NSString stringWithFormat:@"%@", filtered];
    }
    NSData * dictData = [NSJSONSerialization dataWithJSONObject:dateDictArray options:0 error:nil];
    NSString * jsonObj = [[NSString alloc] initWithData:dictData encoding:NSUTF8StringEncoding];
    NSString* eventStr = [NSString stringWithFormat:@"var events = %@;", jsonObj];
    update(eventStr, @"events");

    dateDict = nil;
    dateDictArray = nil;
    dictData = nil;
    jsonObj = nil;
    eventStr = nil;


    //Reminders
    // [store requestAccessToEntityType:EKEntityTypeReminder completion:^(BOOL granted, NSError *error) {
    //     NSLog(@"CalTest acces to §Reminder granded %i ",granted);
    // }];

    NSPredicate *predicate2 = [store predicateForRemindersInCalendars:nil];
    [store fetchRemindersMatchingPredicate:predicate2 completion:^(NSArray *reminders) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *eventsDictArray = [[NSMutableArray alloc] init];
            NSMutableDictionary *eventsDict;
            for (EKReminder *object in reminders) {
                //NSLog(@"CalTest eventes %@", object);
                //NSLog(@"CalTest evernt %@", object.dueDate);
                if(!object.completionDate){
                    eventsDict = [[NSMutableDictionary alloc]init];
                    [eventsDict setValue:object.title forKey:@"title"];
                    //[eventsDict setValue:object.dueDate forKey:@"date"];
                    [eventsDictArray addObject:eventsDict];
                }
            }

            NSData * eventData = [NSJSONSerialization dataWithJSONObject:eventsDictArray options:0 error:nil];
            NSString * eventObj = [[NSString alloc] initWithData:eventData encoding:NSUTF8StringEncoding];
            NSString* remindersStr = [NSString stringWithFormat:@"var reminders = %@;", eventObj];
            update(remindersStr, @"reminders");
            eventsDict = nil;
            eventsDictArray = nil;
            eventData = nil;
            eventObj = nil;
            remindersStr = nil;

            });
    }];

    store = nil;
}

/*
	I need a timer to call the weather, so why not use something that gets called frequently.
	Added ram, helps with debugging as well
*/
static void getBattery(){
	SBUIController *SB = [objc_getClass("SBUIController") sharedInstanceIfExists];
    int batteryCharging = [SB isOnAC];
    int batteryPercent = [SB batteryCapacityAsPercentage];
    int ramFree = ramDataForType(1);
    int ramUsed = ramDataForType(2);
    int ramAvailable = ramDataForType(0);
    int ramPhysical = ramDataForType(-1);
    NSString* battery = [NSString stringWithFormat:@"var batteryPercent = %d, batteryCharging = %d, ramFree = %d, ramUsed = %d, ramAvailable = %d, ramPhysical = %d;", batteryPercent, batteryCharging, ramFree, ramUsed, ramAvailable, ramPhysical];
    update(battery, @"battery");
    getWeather();
    battery = nil;
}

static void getStatusbar(){
    SBWiFiManager *WM = [objc_getClass("SBWiFiManager") sharedInstance];
    SBTelephonyManager *TM = [objc_getClass("SBTelephonyManager") sharedTelephonyManager];
    BluetoothManager *BM = [objc_getClass("BluetoothManager") sharedInstance];

    NSNumber *signalStrength = [NSNumber numberWithInt:[WM signalStrengthRSSI]];
    NSNumber *signalBars = [NSNumber numberWithInt:[WM signalStrengthBars]];
    NSString *signalName = [WM currentNetworkName];

    NSNumber *wifiStrength = [NSNumber numberWithInt:[TM signalStrength]];
    NSNumber *wifiBars = [NSNumber numberWithInt:[TM signalStrengthBars]];
    NSString *wifiName = [WM currentNetworkName];

    NSNumber *blueTooth = [NSNumber numberWithBool: [BM enabled]];

    NSString* statusbar = [NSString stringWithFormat:@"var signalStrength = '%@', signalBars = '%@', signalName = '%@', wifiStrength = '%@', wifiBars = '%@', wifiName = '%@', bluetoothOn = '%@';", signalStrength, signalBars, signalName, wifiStrength, wifiBars, wifiName, blueTooth];
    update(statusbar, @"statusbar");
}

/*
	 delay again. Seems to be my new best friend
	 I use the delay as sometime the artwork takes a second to load
	 from 3rd party music players.
*/
static void getMusic(){
	dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 1.0);
	dispatch_after(delay, dispatch_get_main_queue(), ^(void){
		NSDictionary *info = [objc_getClass("MPUNowPlayingController") _widgetinfo_currentNowPlayingInfo];
	    NSString *artist = [[NSString stringWithFormat:@"%@",[info objectForKey:@"kMRMediaRemoteNowPlayingInfoArtist"]] stringByReplacingOccurrencesOfString:@"'" withString:@""];
	    NSString *album = [[NSString stringWithFormat:@"%@",[info objectForKey:@"kMRMediaRemoteNowPlayingInfoAlbum"]] stringByReplacingOccurrencesOfString:@"'" withString:@""];
	    NSString *title = [[NSString stringWithFormat:@"%@",[info objectForKey:@"kMRMediaRemoteNowPlayingInfoTitle"]] stringByReplacingOccurrencesOfString:@"'" withString:@""];
	    int isplaying = [[objc_getClass("SBMediaController") sharedInstance] isPlaying];
	    UIImage *uiimage = nil;

	    if([objc_getClass("MPUNowPlayingController") _widgetinfo_albumArt]){
	        uiimage = [objc_getClass("MPUNowPlayingController") _widgetinfo_albumArt];
	        [UIImagePNGRepresentation(uiimage) writeToFile:@"var/mobile/Documents/Artwork.jpg" atomically:YES];
	    }

    	NSString* music = [NSString stringWithFormat:@"var artist = '%@', album = '%@', title = '%@', isplaying = %d;", artist, album, title, isplaying];
    	update(music, @"music");

    	info = nil;
    	artist = nil;
    	album = nil;
    	title = nil;
    	isplaying = nil;
    	uiimage = nil;
    	music = nil;
	});
}

%hook MPUNowPlayingController
- (id)init {
    id orig = %orig;
    globalMPUNowPlaying = orig;
    return orig;
}

%new
+(id)_widgetinfo_currentNowPlayingInfo {
    return [globalMPUNowPlaying currentNowPlayingInfo];
}

%new
+(id)_widgetinfo_albumArt{
	if([globalMPUNowPlaying currentNowPlayingArtwork] == NULL){
		MPUNowPlayingController *nowPlayingController=[[objc_getClass("MPUNowPlayingController") alloc] init];
		[nowPlayingController startUpdating];
		return [nowPlayingController currentNowPlayingArtwork];
	}
	return [globalMPUNowPlaying currentNowPlayingArtwork];
}
%end

%hook SBStatusBarStateAggregator
- (void)_notifyItemChanged:(int)arg1{
    getStatusbar();
    %orig;
}
%end

%hook SBUIController
- (void)updateBatteryState:(id)arg1{
		getBattery();
	%orig;
}
%end

%hook SBMediaController
- (void)_nowPlayingInfoChanged{
	getMusic();
	return %orig;
}
%end

/*
	 hook if on lockscreen no need to update anything as iWidget are only on the SB
*/
%hook SpringBoard
-(void)frontDisplayDidChange:(id)newDisplay {
    %orig(newDisplay);
    if ([newDisplay isKindOfClass:%c(SBDashBoardViewController)]) {
        isOnSB = false;
    }
}
%end

/*
	Reversing iWidgets I found this which grabs all taps to the widget.
	Seems to be a good place to capture a variable that could change
	the variable would be defined in the iWidget widget.
	window.setCommands is that global variable.

	SOOO yes, we now have communication to the widget, and communication (some what) from the widget
	full circle, we can now do some ****!

	Note: This can trigger multiple times with one tap. Used dispatch_after to stop that!

 */
%hook IWWidget
-(id)hitTest:(CGPoint)arg1 withEvent:(id)arg2{
	UIView* sel = (UIView *)%orig;
	if([sel isKindOfClass:[UIWebBrowserView class]]){
        IWWidget* widget = (IWWidget*)sel.superview;
        UIWebView *webView = MSHookIvar<UIWebView*>(widget, "_webView");
		dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 0.1);
	 	dispatch_after(delay, dispatch_get_main_queue(), ^(void){
	   		NSString* string = [webView stringByEvaluatingJavaScriptFromString:@"window.sendCommands"];
	   		NSArray *array = [string componentsSeparatedByString:@":"];
	   		if([array count] > 1){

	   			if(lastCalledTouch > 0){
	   				lastCalledTouch = 0;
	   				dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 1.0);
	 				dispatch_after(delay, dispatch_get_main_queue(), ^(void){
	 					lastCalledTouch = 1;
	 				});
		   			/* MUSIC */
		   			if([array[0] isEqualToString:@"music"]){
		   				if([array[1] isEqualToString:@"playpause"]){
		   					[[objc_getClass("SBMediaController") sharedInstance] performSelectorOnMainThread:@selector(togglePlayPause) withObject:nil waitUntilDone:NO];
		   				}
		   				if([array[1] isEqualToString:@"play"]){
		   					[[objc_getClass("SBMediaController") sharedInstance] performSelectorOnMainThread:@selector(play) withObject:nil waitUntilDone:NO];
		   				}
		   				if([array[1] isEqualToString:@"pause"]){
		   					[[objc_getClass("SBMediaController") sharedInstance] performSelectorOnMainThread:@selector(pause) withObject:nil waitUntilDone:NO];
		   				}
		   				if([array[1] isEqualToString:@"next"]){
		   					[[objc_getClass("SBMediaController") sharedInstance] changeTrack:1];
		   				}
		   				if([array[1] isEqualToString:@"prev"]){
		   					[[objc_getClass("SBMediaController") sharedInstance] changeTrack:-1];
		   				}
		   			}
		   			/* APPS */
		   			if([array[0] isEqualToString:@"app"]){
		   				[[objc_getClass("UIApplication") sharedApplication] launchApplicationWithIdentifier:array[1] suspended:NO];
		   			}

                    /* AppDrawer */
                    if([array[0] isEqualToString:@"appdrawer"]){
                        if([[objc_getClass("SBUIController") sharedInstanceIfExists] respondsToSelector:@selector(openAppDrawer)]){
                            [[objc_getClass("SBUIController") sharedInstanceIfExists] openAppDrawer];
                        }
                    }

		   			if([array[0] isEqualToString:@"weather"]){
		   				//getWeather();
		   				refreshWeather(); //bypass the time interval
		   			}
		   		}
	   		}
	 	});
        [webView stringByEvaluatingJavaScriptFromString:@"window.sendCommands = '';"];
	}
	return %orig;
}

/*
	Calls on respring or when a widget is added.
	Grab webview and add to array so we always have a reference.
	Also trigger information (when a widget is added we want new info)
*/
- (void)webView:(id)arg1 didClearWindowObject:(id)arg2 forFrame:(id)arg3 {
     UIWebView *webView = MSHookIvar<UIWebView*>(self, "_webView");
     if(![_widgets containsObject:webView]){
     	[_widgets addObject:webView];
     }

     dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 0.1);
	 dispatch_after(delay, dispatch_get_main_queue(), ^(void){
	   getBattery();
	   getMusic();
       getEvents();
       getStatusbar();
	   if(isOnSB){
	   	refreshWeather();
	   }
	 });

     %orig;
}
%end

/*
	Hook the unlock, so we always have fresh (so fresh and so clean clean) info
	when widgets are shown.
*/
%hook SBLockScreenManager
	-(void)_finishUIUnlockFromSource:(int)arg1 withOptions:(id)arg2 {
		isOnSB = true;
		getBattery();
		getMusic();
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 0.2);
        dispatch_after(delay, dispatch_get_main_queue(), ^(void){
            getEvents(); //todo find something that hooks events so I can display when the event is changed instead of lock/unlock
        });
        //refreshWeather();
		%orig;
	}
%end

/*
	When a widget is removed we need to remove it from our array.
	Finding this really made this work, like at all.
*/
%hook IWWidgetsView
	-(void)removeWidget:(id)arg1{
		IWWidget* main = arg1;
		for (UIView *subview in main.subviews) {
		      if([subview isKindOfClass:[UIWebBrowserView class]]){
		          IWWidget* widget = (IWWidget*)subview.superview;
		          UIWebView *webView = MSHookIvar<UIWebView*>(widget, "_webView");
		          if([_widgets containsObject:webView]){
     					[_widgets removeObject:webView];
     				}
		      }
		}
		%orig;
	}
%end


/* Widget Previews: Tap hold iwidget in list to show preview.jpg */
static UITableView* currentTableView;
static UIView* preview;

static void showPreview(NSString *name){
    CGRect screenFrame = [[UIScreen mainScreen] bounds];
    NSString* path = [NSString stringWithFormat:@"var/mobile/Library/iWidgets/%@/preview.jpg",name];
    UIImageView *imageview = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, screenFrame.size.width, screenFrame.size.height)];

    preview=[[UIView alloc]initWithFrame:CGRectMake(0, 0, screenFrame.size.width, screenFrame.size.height)];

    [imageview setImage:[UIImage imageWithContentsOfFile:path]];
    [imageview setContentMode:UIViewContentModeScaleAspectFit];
    [preview addSubview: imageview];

    UIView* topView = [UIApplication sharedApplication].keyWindow;

    preview.transform = CGAffineTransformScale(CGAffineTransformIdentity, 0.001, 0.001);

    [topView addSubview:preview];

    [UIView animateWithDuration:0.1 animations:^{
        preview.transform = CGAffineTransformScale(CGAffineTransformIdentity, 1.0, 1.0);
    } completion:^(BOOL finished) {
        preview.transform = CGAffineTransformIdentity;
    }];
}

%hook IWWidgetsPopup
    -(long long)tableView:(id)arg1 numberOfRowsInSection:(long long)arg2{
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                      initWithTarget:self action:@selector(tapGesture:)];
                    lp.minimumPressDuration = 0.3; //seconds
                    [arg1 addGestureRecognizer:lp];
        currentTableView = arg1;
        return %orig;
    }

    %new
    -(void)tapGesture:(UITapGestureRecognizer *)sender{
        CGPoint p = [sender locationInView:currentTableView];
        NSIndexPath *indexPath = [currentTableView indexPathForRowAtPoint:p];
        UITableViewCell *cell = [currentTableView cellForRowAtIndexPath:indexPath];
        if (sender.state == UIGestureRecognizerStateEnded) {
          [preview removeFromSuperview];
         }else if (sender.state == UIGestureRecognizerStateBegan){
           showPreview(cell.textLabel.text);
         }
    }
%end






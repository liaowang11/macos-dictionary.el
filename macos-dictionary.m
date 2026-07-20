// macos-dictionary.m --- macOS Dictionary Services command-line interface
// Build: clang -framework CoreServices -framework Foundation macos-dictionary.m -o macos-dictionary-cli
// Usage: macos-dictionary-cli WORD | macos-dictionary-cli --list

#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>

extern CFArrayRef DCSGetActiveDictionaries(void);
extern CFStringRef DCSDictionaryGetName(DCSDictionaryRef dictionary);
extern CFStringRef DCSDictionaryGetShortName(DCSDictionaryRef dictionary);
extern CFArrayRef DCSCopyRecordsForSearchString(DCSDictionaryRef dictionary,
                                                CFStringRef string,
                                                void *options,
                                                void *error);
extern CFStringRef DCSRecordGetHeadword(CFTypeRef record);
extern CFStringRef DCSRecordCopyData(CFTypeRef record, long version);

static NSArray *activeDictionaries(void) {
  CFArrayRef dictionaries = DCSGetActiveDictionaries();
  return dictionaries ? (NSArray *)dictionaries : [NSArray array];
}

static NSString *dictionaryName(DCSDictionaryRef dictionary) {
  CFStringRef name = DCSDictionaryGetName(dictionary);
  return name ? (NSString *)name : @"";
}

static NSString *dictionaryShortName(DCSDictionaryRef dictionary) {
  CFStringRef name = DCSDictionaryGetShortName(dictionary);
  return name ? (NSString *)name : @"";
}

static NSDictionary *dictionaryDescription(DCSDictionaryRef dictionary) {
  return [NSDictionary dictionaryWithObjectsAndKeys:
      dictionaryName(dictionary), @"name",
      dictionaryShortName(dictionary), @"shortName",
      nil];
}

static NSArray *definitionsForWord(NSString *word) {
  NSMutableArray *definitions = [NSMutableArray array];

  for (id dictionaryObject in activeDictionaries()) {
    DCSDictionaryRef dictionary = (DCSDictionaryRef)dictionaryObject;
    CFArrayRef copiedRecords = DCSCopyRecordsForSearchString(
        dictionary, (CFStringRef)word, NULL, NULL);
    if (!copiedRecords) continue;

    NSArray *records = (NSArray *)copiedRecords;
    NSMutableArray *entries = [NSMutableArray array];
    for (id record in records) {
      CFStringRef headwordValue = DCSRecordGetHeadword((CFTypeRef)record);
      if (!headwordValue) continue;

      NSString *headword = (NSString *)headwordValue;
      if ([headword caseInsensitiveCompare:word] != NSOrderedSame) continue;

      CFStringRef htmlValue = DCSRecordCopyData((CFTypeRef)record, 1);
      if (!htmlValue) continue;

      NSString *html = (NSString *)htmlValue;
      [entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
          headword, @"headword",
          html, @"html",
          nil]];
      CFRelease(htmlValue);
    }
    CFRelease(copiedRecords);

    if ([entries count] > 0) {
      [definitions addObject:[NSDictionary dictionaryWithObjectsAndKeys:
          dictionaryName(dictionary), @"name",
          dictionaryShortName(dictionary), @"shortName",
          entries, @"entries",
          nil]];
    }
  }

  return definitions;
}

static BOOL printJSON(id value) {
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                                 options:0
                                                   error:&error];
  if (!data) {
    fprintf(stderr, "%s\n", [[error localizedDescription] UTF8String]);
    return NO;
  }

  fwrite([data bytes], 1, [data length], stdout);
  fputc('\n', stdout);
  return YES;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc != 2) {
      fprintf(stderr, "Usage: macos-dictionary-cli WORD | macos-dictionary-cli --list\n");
      return 2;
    }

    if (strcmp(argv[1], "--list") == 0) {
      NSMutableArray *dictionaries = [NSMutableArray array];
      for (id dictionaryObject in activeDictionaries()) {
        [dictionaries addObject:dictionaryDescription(
            (DCSDictionaryRef)dictionaryObject)];
      }
      return printJSON(dictionaries) ? 0 : 1;
    }

    NSString *word = [NSString stringWithUTF8String:argv[1]];
    if (!word || [word length] == 0) return 2;

    NSDictionary *result = [NSDictionary dictionaryWithObjectsAndKeys:
        word, @"word",
        definitionsForWord(word), @"dictionaries",
        nil];
    return printJSON(result) ? 0 : 1;
  }
}

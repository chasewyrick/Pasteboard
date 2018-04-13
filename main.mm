#include <objc/runtime.h>
#include <objc/message.h>
#include <substrate.h>
#include <pthread.h>
#include <magic.h>
#include <dlfcn.h>

#include <getopt.h> // getopt_long()
#include <libgen.h> // basename()

#import <UIKit/UIPasteboard.h>
#import <MobileCoreServices/MobileCoreServices.h>

//#include <unistd.h>
//#include <sys/syslimits.h> // PATH_MAX
//#include <fcntl.h> // fcntl()

#define _LOGX {fprintf(stderr, "XXX passing line %d %s\n", __LINE__, __PRETTY_FUNCTION__);}
#if 01
#define LOGX _LOGX
#else
#define LOGX
#endif

// UIKit fixes
// kUIKitTypeColor doesn't actually exist but we make it to be consistent and use constants.
NSString * const kUIKitTypeColor = @"com.apple.uikit.color";
void (*_UIPasteboardInitialize)();

NSString * const kPBPrivateTypeDefault = @"private.default";

typedef NS_ENUM(NSUInteger, PBPasteboardMode) {
	PBPasteboardModeNoop,
	PBPasteboardModeCopy,
	PBPasteboardModePaste,
};

typedef NS_ENUM(NSUInteger, PBPasteboardType) {
	PBPasteboardTypeDefault,
	PBPasteboardTypeString,
	PBPasteboardTypeURL,
	PBPasteboardTypeImage,
	PBPasteboardTypeColor,
};

static NSArray const * types = nil;
static void PBPasteboardOnce(void) {
	types = [NSArray arrayWithObjects:
			kPBPrivateTypeDefault,
			(id)kUTTypeText,
			(id)kUTTypeURL,
			(id)kUTTypePNG,
			kUIKitTypeColor,
			nil
		];
}

const char * PBPasteboardTypeGetStringFromType(PBPasteboardType type) {
	pthread_once_t once = PTHREAD_ONCE_INIT;
	pthread_once(&once, &PBPasteboardOnce);
	return ((NSString *)types[type]).UTF8String;
}

static char * filePathFromFd(int fd) {
	char * path = NULL;
	char filePath[PATH_MAX];
	if (fcntl(fd, F_GETPATH, filePath) != -1) {
		path = strdup(filePath);
	}
	return path;
}

NSString * PBFilePathFromFd(int fd) {
	char * filePath = filePathFromFd(fd);
	if (!filePath) {
		return nil;
	}
	NSString * string = [[NSString alloc] initWithUTF8String:filePath];
	free(filePath);
	return [string autorelease];
}

NSString * PBUTIStringFromFilePath(NSString * filePath) {
	NSString * type = (id)kUTTypeUTF8PlainText;
	if (!filePath) {
		return type;
	}

	magic_t cookie = magic_open(MAGIC_MIME_TYPE);
	const char *magic=NULL;
	if (cookie && magic_load(cookie, NULL)==0 && (magic = magic_file(cookie, filePath.UTF8String))) {
		NSString *uti = (id)UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (CFStringRef)@(magic), NULL);
		if ([uti hasPrefix:@"dyn."]) {
			uti = (id)UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (CFStringRef)filePath.pathExtension, NULL);
			if ([uti hasPrefix:@"dyn."]) {
				[uti release];
				uti = nil;
			}
		}
		if (uti)
			type = uti;
	} else {
		fprintf(stderr, "no magic for %s :( (%s)\n", filePath.UTF8String, magic_error(cookie));
	}

	//fprintf(stderr, "Detected type: %s for mime magic %s\n", type.UTF8String, magic);

	magic_close(cookie);
	return [type autorelease];
}

PBPasteboardType PBPasteboardTypeOfFd(int fd) {
	@autoreleasepool {
		NSString * path = PBFilePathFromFd(fd);
		NSString * UTI = PBUTIStringFromFilePath(path);
		//fprintf(stderr, "UTI %s\n", UTI.UTF8String);

		NSArray * typesArray = [NSArray arrayWithObjects:
			[NSArray arrayWithObjects: kPBPrivateTypeDefault, nil],
			UIPasteboardTypeListString,
			UIPasteboardTypeListURL,
			UIPasteboardTypeListImage,
			UIPasteboardTypeListColor,
			nil
		];
		NSUInteger index = 0;
		for (NSArray * types in typesArray) {
			if ([types containsObject:UTI]) {
				index = [typesArray indexOfObject:types];
				break;
			}
		}
		return (PBPasteboardType)index;
	}
}

char * PBCreateBufferFromFd(int fd, size_t * length) {
	FILE * file = fdopen(fd, "r");
	char c;
	size_t p4kB = 4096, i = 0;
	void * newPtr = NULL;
	char * buffer = (char *)malloc(p4kB * sizeof(char));

	while (buffer != NULL && (fscanf(file, "%c", &c) != EOF)) {
		if (i == p4kB * sizeof(char)) {
			p4kB += 4096;
			if ((newPtr = realloc(buffer, p4kB * sizeof(char))) != NULL) {
				buffer = (char *)newPtr;
			} else {
				free(buffer);
				i = 0;
				buffer = NULL;
				break;
			}
		}
		buffer[i++] = c;
	}

	if (buffer != NULL) {
		if ((newPtr = realloc(buffer, (i + 1) * sizeof(char))) != NULL) {
			buffer = (char *)newPtr;
			buffer[i] = '\0';
		} else {
			free(buffer);
			i = 0;
			buffer = NULL;
		}
	}

	if (length) {
		*length = i;
	}
	return buffer;
}

char * PBPasteboardSaveImage(UIPasteboard * generalPb, char * path, size_t * lengthPtr) {
	if (!generalPb) {
		return NULL;
	}

	NSString * ext = @(path).pathExtension;
	NSArray * supportedExtensions = [NSArray arrayWithObjects:
		@"png",
		@"jpg",
		nil
	];

	BOOL success = NO;
	NSURL * fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"com.uikit.pasteboard.buffer"]];
	NSError * error = nil;
	NSData * data = nil;

	switch ([supportedExtensions indexOfObject:ext]) {
		case 0: {
			data = [generalPb valueForPasteboardType:@"public.png"];
			// This seems to change somewhere between iOS3 and 11 :|
			if ([data isKindOfClass:[UIImage class]]) {
				data = UIImagePNGRepresentation((UIImage*)data);
			}
		} break;

		case 1: {
			data = [generalPb valueForPasteboardType:@"public.jpg"];
			// This seems to change somewhere between iOS3 and 11 :|
			if ([data isKindOfClass:[UIImage class]]) {
				data = UIImageJPEGRepresentation((UIImage*)data, 1.0);
			}
		} break;
		default: {
			fprintf(stderr,
				"Extension '%s' not supported.\n"
				, ext.UTF8String
			);
		} break;
	}

	if (data) {
		if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&error]) {
			fprintf(stderr, "Error <%s>.\n", error.description.UTF8String);
			return NULL;
		}
		success = YES;
	}

	char * buffer = NULL;
	if (success) {
		int fd = open(fileURL.path.UTF8String, O_RDONLY);
		size_t length = 0;
		buffer = PBCreateBufferFromFd(fd, &length);
		close(fd);
		[NSFileManager.defaultManager removeItemAtPath:fileURL.path error:&error];
		if (length > 0) {
			*lengthPtr = length;
		}
	}
	return buffer;
}

void PBPasteboardPerformCopy(int fd, PBPasteboardType overrideType) {
	NSString *inType = (overrideType != PBPasteboardTypeDefault) ? types[overrideType] : PBUTIStringFromFilePath(PBFilePathFromFd(fd));

	UIPasteboard * generalPb = UIPasteboard.generalPasteboard;

	if (UTTypeConformsTo((CFStringRef)inType, kUTTypePlainText)) {
			size_t length = 0;
			char * string = PBCreateBufferFromFd(fd, &length);
			if (length < 1) {
				return;
			}
			// Force kUTTypeUTF8PlainText instead of kUTTypePlainText
			// TODO: Only do this for older iOS versions that are broken for plain-text
			[generalPb setValue:@(string) forPasteboardType:(id)kUTTypeUTF8PlainText];
			free(string);
	} else {
			char * path = filePathFromFd(fd);
			NSString *nsPath = @(path);
			free(path);
			generalPb.items =  @[@{inType : [NSData dataWithContentsOfFile:nsPath], (id)kUTTypeUTF8PlainText : [nsPath lastPathComponent]}];
	}
}

void PBPasteboardPerformPaste(int fd, PBPasteboardType overrideType) {
	PBPasteboardType outType = (overrideType != PBPasteboardTypeDefault) ? overrideType : PBPasteboardTypeOfFd(fd);

	UIPasteboard * generalPb = UIPasteboard.generalPasteboard;
	//CFShow(generalPb.items);
	FILE *stream = fdopen(fd, "w");
	if (!stream) {
		fprintf(stderr, "ERROR: %s\n", strerror(errno));
		return;
	}

	//const char * outTypeString = PBPasteboardTypeGetStringFromType(outType);
	//fprintf(stderr, "paste: Resource type <%s>.\n", outTypeString);

	switch (outType) {
		default: {
			//NSString * path = PBFilePathFromFd(fd);
			//NSString * actualUTI = PBUTIStringFromFilePath(path);
			//fprintf(stderr, "paste: Resource type <%s> unsupported. Performing default action.\n", actualUTI.UTF8String);
		}
		case PBPasteboardTypeString: {
			if (generalPb.string) {
				fprintf(stream, "%s", generalPb.string.UTF8String);
			} else {
				fprintf(stream, "\n");
			}
		} break;

		case PBPasteboardTypeImage: {
			char * path = filePathFromFd(fd);
			size_t length = 0;
			char * raw = PBPasteboardSaveImage(generalPb, path, &length);
			if (!raw) {
				fprintf(stderr, "No buffer.\n");
				break;
			}
			write(fd, raw, length);
			free(path);
		} break;
	}

}

void PBPasteboardPrintHelp(int argc, char **argv, char **envp) {
	fprintf(stderr,
		"Usage: %s [OPTION]\n"
		"\n"
		"Overview: copy and paste items to the global pasteboard. Supports piping in and out as well as to files. It will try to automatically determine the file type based on the file extension and use the according pasteboard value.\n"
		"Currently supported extensions:\n"
		"  txt -> string\n"
		"  jpg, png -> image\n"
		"\n"
		"Options:\n"
		"  -h,--help      Print this help.\n"
		"  -s,--string    Force type to be the string value if available.\n"
		"  -u,--url       Force type to be the URL value if available.\n"
		"  -i,--image     Force type to be the image value if available.\n"
		"  -c,--color     Force type to be the color value if available.\n"
		, basename(argv[0])
	);
}

int main(int argc, char **argv, char **envp) {
	// This would work for anything with working Substrate but apparently dies under Substitute
	dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
	MSImageRef image = MSGetImageByName("/System/Library/Frameworks/UIKit.framework/UIKit");
	if (image == NULL) {
		fprintf(stderr, "Error: Unable to find UIKit?\?!?\n");
		exit(1);
	}
	_UIPasteboardInitialize = (void (*)(void))MSFindSymbol(image, "__UIPasteboardInitialize");
	if (_UIPasteboardInitialize == NULL) {
		fprintf(stderr, "Error: Couldn't find _UIPasteboardInitialize\n");
		exit(1);
	}
	@autoreleasepool {
		_UIPasteboardInitialize();
		int help_flag = 0;
		PBPasteboardType overrideType = PBPasteboardTypeDefault;

		// Process options
		struct option long_options[] = {
			{ "help",   no_argument, NULL, 'h' },
			{ "string", no_argument, NULL, 's' },
			{ "url",    no_argument, NULL, 'u' },
			{ "image",  no_argument, NULL, 'i' },
			{ "color",  no_argument, NULL, 'c' },
			/* End of options. */
			{ 0, 0, 0, 0 }
		};

		int opt;
		int option_index = 0;
		while ((opt = getopt_long(argc, argv, "hsuic", long_options, &option_index)) != -1) {
			switch (opt) {
			case 's':
				if (overrideType == PBPasteboardTypeDefault) {
					overrideType = PBPasteboardTypeString;
				} else {
					fprintf(stderr, "Cannot set multiple pasteboard types.\n");
				}
				break;

			case 'u':
				if (overrideType == PBPasteboardTypeDefault) {
					overrideType = PBPasteboardTypeURL;
				} else {
					fprintf(stderr, "Cannot set multiple pasteboard types.\n");
				}
				break;

			case 'i':
				if (overrideType == PBPasteboardTypeDefault) {
					overrideType = PBPasteboardTypeImage;
				} else {
					fprintf(stderr, "Cannot set multiple pasteboard types.\n");
				}
				break;

			case 'c':
				if (overrideType == PBPasteboardTypeDefault) {
					overrideType = PBPasteboardTypeColor;
				} else {
					fprintf(stderr, "Cannot set multiple pasteboard types.\n");
				}
				break;

			default:
			case 'h':
				help_flag = 1;
				break;
			}
		}

		if (help_flag) {
			PBPasteboardPrintHelp(argc, argv, envp);
			return 0;
		}

		int inFD = STDIN_FILENO;
		int outFD = STDOUT_FILENO;

		PBPasteboardMode mode =
			isatty(inFD) ? PBPasteboardModePaste :
			isatty(outFD) ? PBPasteboardModeCopy :
			PBPasteboardModeCopy | PBPasteboardModePaste;

		if (mode & PBPasteboardModeCopy) {
			PBPasteboardPerformCopy(inFD, overrideType);
		}

		if (mode & PBPasteboardModePaste) {
			PBPasteboardPerformPaste(outFD, overrideType);
		}
	}
	return 0;
}

// vim:ft=objc

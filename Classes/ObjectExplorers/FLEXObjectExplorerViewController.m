//
//  FLEXObjectExplorerViewController.m
//  Flipboard
//
//  Created by Ryan Olson on 2014-05-03.
//  Copyright (c) 2014 Flipboard. All rights reserved.
//

#import "FLEXObjectExplorerViewController.h"
#import "FLEXUtility.h"
#import "FLEXRuntimeUtility.h"
#import "UIBarButtonItem+FLEX.h"
#import "FLEXMultilineTableViewCell.h"
#import "FLEXObjectExplorerFactory.h"
#import "FLEXFieldEditorViewController.h"
#import "FLEXMethodCallingViewController.h"
#import "FLEXInstancesViewController.h"
#import "FLEXTabsViewController.h"
#import "FLEXBookmarkManager.h"
#import "FLEXTableView.h"
#import "FLEXTableViewCell.h"
#import "FLEXScopeCarousel.h"
#import "FLEXMetadataSection.h"
#import "FLEXSingleRowSection.h"
#import "FLEXShortcutsSection.h"
#import <objc/runtime.h>

#pragma mark - Private properties
@interface FLEXObjectExplorerViewController () <UIGestureRecognizerDelegate>

@property (nonatomic, copy) NSString *filterText;
/// Every section in the table view, regardless of whether or not a section is empty.
@property (nonatomic, readonly) NSArray<FLEXTableViewSection *> *allSections;
/// Only displayed sections of the table view; empty sections are purged from this array.
@property (nonatomic) NSArray<FLEXTableViewSection *> *sections;
@property (nonatomic, readonly) FLEXSingleRowSection *descriptionSection;
@property (nonatomic, readonly) FLEXTableViewSection *customSection;
@property (nonatomic) NSIndexSet *customSectionVisibleIndexes;

@end

@implementation FLEXObjectExplorerViewController

#pragma mark - Initialization

+ (instancetype)exploringObject:(id)target {
    return [self exploringObject:target customSection:[FLEXShortcutsSection forObject:target]];
}

+ (instancetype)exploringObject:(id)target customSection:(FLEXTableViewSection *)section {
    return [[self alloc]
        initWithObject:target
        explorer:[FLEXObjectExplorer forObject:target]
        customSection:section
    ];
}

- (id)initWithObject:(id)target
            explorer:(__kindof FLEXObjectExplorer *)explorer
       customSection:(FLEXTableViewSection *)customSection {
    NSParameterAssert(target);
    
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _object = target;
        _explorer = explorer;
        _customSection = customSection;
        _allSections = [self makeSections];
    }

    return self;
}

#pragma mark - View controller lifecycle

- (void)loadView {
    [super loadView];

    // Register cell classes
    for (FLEXTableViewSection *section in self.allSections) {
        if (section.cellRegistrationMapping) {
            [self.tableView registerCells:section.cellRegistrationMapping];
        }
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.showsShareToolbarItem = YES;

    // Use [object class] here rather than object_getClass
    // to avoid the KVO prefix for observed objects
    self.title = [[self.object class] description];

    // Search
    self.showsSearchBar = YES;
    self.searchBarDebounceInterval = kFLEXDebounceInstant;
    self.showsCarousel = YES;

    // Carousel scope bar
    [self.explorer reloadClassHierarchy];
    self.carousel.items = [self.explorer.classHierarchyClasses flex_mapped:^id(Class cls, NSUInteger idx) {
        return NSStringFromClass(cls);
    }];

    // Swipe gestures to swipe between classes in the hierarchy
    UISwipeGestureRecognizer *leftSwipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleSwipeGesture:)
    ];
    UISwipeGestureRecognizer *rightSwipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleSwipeGesture:)
    ];
    leftSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
    rightSwipe.direction = UISwipeGestureRecognizerDirectionRight;
    leftSwipe.delegate = self;
    rightSwipe.delegate = self;
    [self.tableView addGestureRecognizer:leftSwipe];
    [self.tableView addGestureRecognizer:rightSwipe];
}


#pragma mark - Private

- (NSArray<FLEXTableViewSection *> *)makeSections {
    FLEXObjectExplorer *explorer = self.explorer;
    
    // Description section is only for instances
    if (self.explorer.objectIsInstance) {
        _descriptionSection = [FLEXSingleRowSection
             title:@"Description" reuse:kFLEXMultilineCell cell:^(FLEXTableViewCell *cell) {
                 cell.titleLabel.font = UIFont.flex_defaultTableCellFont;
                 cell.titleLabel.text = explorer.objectDescription;
             }
        ];
        self.descriptionSection.filterMatcher = ^BOOL(NSString *filterText) {
            return [explorer.objectDescription localizedCaseInsensitiveContainsString:filterText];
        };
    }

    // Object graph section
    FLEXSingleRowSection *referencesSection = [FLEXSingleRowSection
        title:@"Object Graph" reuse:kFLEXDefaultCell cell:^(FLEXTableViewCell *cell) {
            cell.titleLabel.text = @"See Objects with References to This Object";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    ];
    referencesSection.selectionAction = ^(UIViewController *host) {
        UIViewController *references = [FLEXInstancesViewController
            instancesTableViewControllerForInstancesReferencingObject:explorer.object
        ];
        [host.navigationController pushViewController:references animated:YES];
    };

    NSMutableArray *sections = [NSMutableArray arrayWithArray:@[
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindProperties],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindClassProperties],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindIvars],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindMethods],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindClassMethods],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindClassHierarchy],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindProtocols],
        [FLEXMetadataSection explorer:self.explorer kind:FLEXMetadataKindOther],
        referencesSection
    ]];

    if (self.customSection) {
        [sections insertObject:self.customSection atIndex:0];
    }
    if (self.descriptionSection) {
        [sections insertObject:self.descriptionSection atIndex:0];
    }

    return sections.copy;
}

- (NSArray<FLEXTableViewSection *> *)nonemptySections {
    return [self.allSections flex_filtered:^BOOL(FLEXTableViewSection *section, NSUInteger idx) {
        return section.numberOfRows > 0;
    }];
}

- (BOOL)sectionHasActions:(NSInteger)section {
    return self.sections[section] == self.descriptionSection;
}

- (void)handleSwipeGesture:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded) {
        switch (gesture.direction) {
            case UISwipeGestureRecognizerDirectionRight:
                if (self.selectedScope > 0) {
                    self.selectedScope -= 1;
                }
                break;
            case UISwipeGestureRecognizerDirectionLeft:
                if (self.selectedScope != self.explorer.classHierarchy.count - 1) {
                    self.selectedScope += 1;
                }
                break;

            default:
                break;
        }
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g1 shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)g2 {
    // Prioritize important pan gestures over our swipe gesture
    if ([g2 isKindOfClass:[UIPanGestureRecognizer class]]) {
        if (g2 == self.navigationController.interactivePopGestureRecognizer ||
            g2 == self.navigationController.barHideOnSwipeGestureRecognizer ||
            g2 == self.tableView.panGestureRecognizer) {
            return NO;
        }
    }
    
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UISwipeGestureRecognizer *)gesture {
    // Don't allow swiping from the carousel
    CGPoint location = [gesture locationInView:self.tableView];
    if ([self.carousel hitTest:location withEvent:nil]) {
        return NO;
    }
    
    return YES;
}

- (void)shareButtonPressed {
    [FLEXAlert makeSheet:^(FLEXAlert *make) {
        make.button(@"Add to Bookmarks").handler(^(NSArray<NSString *> *strings) {
            [FLEXBookmarkManager.bookmarks addObject:self.object];
        });
        make.button(@"Copy Description").handler(^(NSArray<NSString *> *strings) {
            UIPasteboard.generalPasteboard.string = self.explorer.objectDescription;
        });
        make.button(@"Copy Address").handler(^(NSArray<NSString *> *strings) {
            [self copyObjectAddress:nil];
        });
        make.button(@"Cancel").cancelStyle();
    } showFrom:self];
}

#pragma mark - Description

- (BOOL)shouldShowDescription {
    // Hide if we have filter text; it is rarely
    // useful to see the description when searching
    // since it's already at the top of the screen
    if (self.filterText.length) {
        return NO;
    }

    return YES;
}


#pragma mark - Search

- (void)updateSearchResults:(NSString *)newText; {
    self.filterText = newText;

    // Sections will adjust data based on this property
    for (FLEXTableViewSection *section in self.allSections) {
        section.filterText = newText;
    }

    // Check to see if class scope changed, update accordingly
    if (self.explorer.classScope != self.selectedScope) {
        self.explorer.classScope = self.selectedScope;
        for (FLEXTableViewSection *section in self.allSections) {
            [section reloadData];
        }
    }

    // Recalculate empty sections
    self.sections = [self nonemptySections];

    // Refresh table view
    if (self.isViewLoaded) {
        [self.tableView reloadData];
    }
}


#pragma mark - Reloading

- (void)reloadData {
    // Reload explorer
    [self.explorer reloadMetadata];

    // Reload sections
    for (FLEXTableViewSection *section in self.allSections) {
        [section reloadData];
    }

    // Recalculate displayed sections
    self.sections = [self nonemptySections];

    // Refresh table view
    if (self.isViewLoaded) {
        [self.tableView reloadData];
    }
}


#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].numberOfRows;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[section].title;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *reuse = [self.sections[indexPath.section] reuseIdentifierForRow:indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse forIndexPath:indexPath];
    [self.sections[indexPath.section] configureCell:cell forRow:indexPath.row];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // For the description section, we want that nice slim/snug looking row.
    // Other rows use the automatic size.
    FLEXTableViewSection *section = self.sections[indexPath.section];
    
    if (section == self.descriptionSection) {
        NSAttributedString *attributedText = [[NSAttributedString alloc]
            initWithString:self.explorer.objectDescription
            attributes:@{ NSFontAttributeName : UIFont.flex_defaultTableCellFont }
        ];
        
        return [FLEXMultilineTableViewCell
            preferredHeightWithAttributedText:attributedText
            maxWidth:tableView.frame.size.width - tableView.separatorInset.right
            style:tableView.style
            showsAccessory:NO
        ];
    }

    return UITableViewAutomaticDimension;
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tableView {
    return [self.sections flex_mapped:^id(FLEXTableViewSection *obj, NSUInteger idx) {
        return @"⦁";
    }];
}


#pragma mark - UITableViewDelegate

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self.sections[indexPath.section] canSelectRow:indexPath.row];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    FLEXTableViewSection *section = self.sections[indexPath.section];

    void (^action)(UIViewController *) = [section didSelectRowAction:indexPath.row];
    UIViewController *details = [section viewControllerToPushForRow:indexPath.row];

    if (action) {
        action(self);
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else if (details) {
        [self.navigationController pushViewController:details animated:YES];
    } else {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Row is selectable but has no action or view controller"];
    }
}

- (BOOL)tableView:(UITableView *)tableView shouldShowMenuForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self sectionHasActions:indexPath.section];
}

- (BOOL)tableView:(UITableView *)tableView canPerformAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender {
    // Only the description section has "actions"
    if (self.sections[indexPath.section] == self.descriptionSection) {
        return action == @selector(copy:);
    }

    return NO;
}

- (void)tableView:(UITableView *)tableView performAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender {
    if (action == @selector(copy:)) {
        UIPasteboard.generalPasteboard.string = self.explorer.objectDescription;
    }
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    [self.sections[indexPath.section] didPressInfoButtonAction:indexPath.row](self);
}

#if FLEX_AT_LEAST_IOS13_SDK

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point __IOS_AVAILABLE(13.0) {
    FLEXTableViewSection *section = self.sections[indexPath.section];
    NSString *title = [section menuTitleForRow:indexPath.row];
    NSArray<UIMenuElement *> *menuItems = [section menuItemsForRow:indexPath.row sender:self];
    
    if (menuItems.count) {
        return [UIContextMenuConfiguration
            configurationWithIdentifier:nil
            previewProvider:nil
            actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
                return [UIMenu menuWithTitle:title children:menuItems];
            }
        ];
    }
    
    return nil;
}

#endif


#pragma mark - UIMenuController

/// Prevent the search bar from trying to use us as a responder
///
/// Our table cells will use the UITableViewDelegate methods
/// to make sure we can perform the actions we want to
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    return NO;
}

- (void)copy:(NSIndexPath *)indexPath {
    FLEXTableViewSection *section = self.sections[indexPath.section];
    UIPasteboard.generalPasteboard.string = ({
        NSString *copy = [section titleForRow:indexPath.row];
        NSString *subtitle = [section subtitleForRow:indexPath.row];

        if (subtitle.length) {
            copy = [NSString stringWithFormat:@"%@\n\n%@", copy, subtitle];
        }

        // If no string was provided, don't overwrite the pasteboard
        copy.length > 2 ? copy : UIPasteboard.generalPasteboard.string;
    });
}

- (void)copyObjectAddress:(NSIndexPath *)indexPath {
    UIPasteboard.generalPasteboard.string = [FLEXUtility addressOfObject:self.object];
}

@end

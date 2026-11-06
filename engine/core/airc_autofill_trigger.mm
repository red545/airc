// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_autofill_trigger.h"

#include <set>
#include <tuple>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "components/autofill/core/browser/suggestions/suggestion.h"
#include "components/autofill/core/browser/suggestions/suggestion_type.h"
#include "components/autofill/content/browser/content_autofill_client.h"
#include "components/autofill/content/browser/content_autofill_driver.h"
#include "components/autofill/core/browser/foundations/autofill_driver.h"
#include "components/autofill/core/browser/foundations/autofill_manager.h"
#include "components/autofill/core/browser/foundations/scoped_autofill_managers_observation.h"
#include "components/autofill/core/common/aliases.h"
#include "components/autofill/core/common/unique_ids.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_widget_host_view.h"
#include "ui/gfx/geometry/rect_f.h"
#import "airc/core/airc_tab_internal.h"
#include "content/public/browser/web_contents_user_data.h"
#include "airc/core/airc_hooks.h"
#include "airc/core/airc_browser.h"
#import "airc/core/airc_internal.h"

namespace airc {

namespace {

using autofill::AutofillManager;
using autofill::AutofillSuggestionTriggerSource;
using autofill::FieldGlobalId;
using autofill::FormGlobalId;

// Passwords never cross the Objective-C API. The host receives display text and
// per-tab, never-reused row handles. A stale UI cannot select a later session.
class PasswordRows : public content::WebContentsUserData<PasswordRows>,
                     public content::WebContentsObserver {
 public:
  bool Show(const autofill::AutofillClient::PopupOpenArgs& args,
            base::WeakPtr<autofill::AutofillSuggestionDelegate> delegate) {
    Hide();
    // Our ChromeAutofillClient hook runs BEFORE its screen-space conversion.
    // These are already root page-view DIPs, with a top-left origin: Blink's
    // BoundsInWidget includes zoom/scroll and ContentAutofillDriver lifts child
    // frame bounds into the root widget. Neither a screen offset nor a backing
    // scale conversion belongs here (including on mixed-scale displays).
    const gfx::RectF& field = args.element_bounds;
    NSString* bounds = NSStringFromRect(
        NSMakeRect(field.x(), field.y(), field.width(), field.height()));
    delegate_ = delegate;
    form_ = args.form_id;
    field_ = args.field_id;
    rows_ = args.suggestions;
    first_ = next_;
    next_ += rows_.size();
    shown_ = base::TimeTicks::Now();
    NSMutableArray* items = [NSMutableArray array];
    std::set<std::tuple<std::u16string, std::string, std::u16string>> seen;
    exposed_.clear();
    for (size_t i = 0; i < rows_.size(); ++i) {
      const auto& row = rows_[i];
      // Password entries only. Manage passwords / passkeys / submenus continue
      // to belong to their own APIs; never offer a nonselectable heading.
      if (!row.IsAcceptable() ||
          (row.type != autofill::SuggestionType::kPasswordEntry &&
           row.type != autofill::SuggestionType::kAccountStoragePasswordEntry)) continue;
      const auto* password = std::get_if<autofill::Suggestion::PasswordSuggestionDetails>(&row.payload);
      if (password && password->is_cross_domain) continue;
      const std::u16string username = password ? password->username : row.main_text.value;
      if (password && !seen.emplace(username, password->signon_realm.value_or(""),
                                     password->password).second) continue;
      exposed_.insert(first_ + i);
      [items addObject:@{@"label":base::SysUTF16ToNSString(username),
                        @"sublabel":password && password->display_signon_realm
                            ? base::SysUTF16ToNSString(*password->display_signon_realm) : @"",
                        @"minorText":@"",
                        @"type":@"password", @"index":[@(first_ + i) stringValue],
                        @"bounds":bounds}];
    }
    delegate_->OnSuggestionsShown(rows_, {});
    Report(items);
    return true;
  }
  bool Accept(int64_t index) {
    auto* frame = web_contents()->GetFocusedFrame();
    if (!delegate_ || !exposed_.contains(index) || index < first_ || index >= first_ + int64_t(rows_.size()) ||
        !frame || autofill::LocalFrameToken(frame->GetFrameToken().value()) != field_.frame_token ||
        delegate_->GetQueriedFieldId() != field_ ||
        base::TimeTicks::Now() - shown_ < base::Milliseconds(500)) return false;
    const size_t row_index = index - first_;
    auto row = rows_[row_index];
    const auto* password = std::get_if<autofill::Suggestion::PasswordSuggestionDetails>(&row.payload);
    if (password && password->is_cross_domain) return false;
    if (!row.IsAcceptable() ||
        (row.type != autofill::SuggestionType::kPasswordEntry &&
         row.type != autofill::SuggestionType::kAccountStoragePasswordEntry)) return false;
    auto delegate = delegate_;
    auto form = form_; auto field = field_;
    // Invalidate before invoking Chromium (it may synchronously hide/reenter).
    rows_.clear(); exposed_.clear(); delegate_.reset();
    Report(@[]);
    if (delegate) delegate->DidAcceptSuggestion(row, {.multi_index={row_index}}, form, field);
    return true;
  }
  void Hide() {
    if (rows_.empty()) return;
    rows_.clear(); exposed_.clear();
    auto delegate = std::exchange(delegate_, {});
    if (delegate) {
      delegate->ClearPreviewedForm();
      delegate->OnSuggestionsHidden(autofill::SuggestionHidingReason::kHiddenByCaller);
    }
    Report(@[]);
  }
 private:
  friend class content::WebContentsUserData<PasswordRows>;
  explicit PasswordRows(content::WebContents* contents)
      : content::WebContentsUserData<PasswordRows>(*contents),
        content::WebContentsObserver(contents) {}
  void DidStartNavigation(content::NavigationHandle* handle) override { Hide(); }
  void RenderFrameDeleted(content::RenderFrameHost* frame) override { Hide(); }
  void OnVisibilityChanged(content::Visibility visibility) override {
    if (visibility != content::Visibility::VISIBLE) Hide();
  }
  void Report(NSArray* items) {
    AircTab* tab = TabBridge::GetOrCreate(web_contents())->tab();
    if ([tab.delegate respondsToSelector:@selector(tab:didShowAutofillSuggestions:)])
      [tab.delegate tab:tab didShowAutofillSuggestions:items];
  }
  base::WeakPtr<autofill::AutofillSuggestionDelegate> delegate_;
  std::vector<autofill::Suggestion> rows_;
  std::set<int64_t> exposed_;
  FormGlobalId form_;
  FieldGlobalId field_;
  int64_t first_ = 0, next_ = 0;
  base::TimeTicks shown_;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};
WEB_CONTENTS_USER_DATA_KEY_IMPL(PasswordRows);

class FocusedField : public content::WebContentsUserData<FocusedField>,
                     public AutofillManager::Observer {
 public:
  FocusedField(const FocusedField&) = delete;
  FocusedField& operator=(const FocusedField&) = delete;
  ~FocusedField() override = default;

  bool Trigger(AutofillSuggestionTriggerSource source) {
    AutofillManager* manager = manager_.get();
    content::RenderFrameHost* frame = GetWebContents().GetFocusedFrame();
    auto* driver =
        frame ? autofill::ContentAutofillDriver::GetForRenderFrameHost(frame)
              : nullptr;
    if (!manager || !driver || !driver->IsActive() ||
        &driver->GetAutofillManager() != manager) {
      return false;
    }
    static_cast<autofill::AutofillDriver*>(driver)
        ->RendererShouldTriggerSuggestions(field_, source);
    return true;
  }

 private:
  friend class content::WebContentsUserData<FocusedField>;

  FocusedField(content::WebContents* web_contents,
               autofill::ContentAutofillClient* client)
      : content::WebContentsUserData<FocusedField>(*web_contents) {
    observation_.Observe(client, autofill::ScopedAutofillManagersObservation::
                                     InitializationPolicy::
                                         kObservePreexistingManagers);
  }

  void OnAfterFocusOnFormField(AutofillManager& manager,
                               FormGlobalId form,
                               FieldGlobalId field) override {
    Focused(manager, field);
  }
  void OnAfterAskForValuesToFill(AutofillManager& manager,
                                 FormGlobalId form,
                                 FieldGlobalId field) override {
    Focused(manager, field);
  }
  void OnAfterFocusOnNonFormField(AutofillManager& manager) override {
    HideHostPasswordSuggestions(&GetWebContents());
    if (manager_.get() == &manager) {
      manager_.reset();
    }
  }

  void Focused(AutofillManager& manager, FieldGlobalId field) {
    if (field_ != field) HideHostPasswordSuggestions(&GetWebContents());
    manager_ = manager.GetWeakPtr();
    field_ = field;
  }

  base::WeakPtr<AutofillManager> manager_;
  FieldGlobalId field_;
  autofill::ScopedAutofillManagersObservation observation_{this};

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(FocusedField);

void ReportShown(content::WebContents* contents,
                 base::span<const autofill::Suggestion> suggestions) {
  if (!contents || !FocusedField::FromWebContents(contents)) {
    return;
  }
  NSMutableArray* items = [NSMutableArray array];
  for (const autofill::Suggestion& suggestion : suggestions) {
    if (suggestion.type == autofill::SuggestionType::kSeparator) {
      continue;
    }
    NSMutableArray* labels = [NSMutableArray array];
    for (const auto& row : suggestion.labels) {
      for (const auto& text : row) {
        if (!text.value.empty()) {
          [labels addObject:base::SysUTF16ToNSString(text.value)];
        }
      }
    }
    NSMutableArray* minor = [NSMutableArray array];
    for (const auto& text : suggestion.minor_texts) {
      if (!text.value.empty()) {
        [minor addObject:base::SysUTF16ToNSString(text.value)];
      }
    }
    [items addObject:@{
      @"label" : base::SysUTF16ToNSString(suggestion.main_text.value),
      @"sublabel" : [labels componentsJoinedByString:@" "],
      @"minorText" : [minor componentsJoinedByString:@" "],
      @"type" : base::SysUTF8ToNSString(autofill::SuggestionTypeToString(suggestion.type)),
    }];
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<content::WebContents> contents, NSArray* items) {
                       if (!contents) {
                         return;
                       }
                       AircTab* tab = TabBridge::GetOrCreate(contents.get())->tab();
                       id<AircTabDelegate> delegate = tab.delegate;
                       if ([delegate respondsToSelector:@selector
                                     (tab:didShowAutofillSuggestions:)]) {
                         [delegate tab:tab didShowAutofillSuggestions:items];
                       }
                     },
                     contents->GetWeakPtr(), items));
}

}

bool HostPasswordSuggestions(content::WebContents* contents,
    const autofill::AutofillClient::PopupOpenArgs& args,
    base::WeakPtr<autofill::AutofillSuggestionDelegate> delegate) {
  if (!contents || !delegate ||
      delegate->GetMainFillingProduct() != autofill::FillingProduct::kPassword) return false;
  AircTab* tab = TabBridge::GetOrCreate(contents)->tab();
  if (![tab.delegate respondsToSelector:@selector(tabWantsPasswordSuggestions:)] ||
      ![tab.delegate tabWantsPasswordSuggestions:tab]) return false;
  auto* view = contents->GetRenderWidgetHostView();
  if (!view || view->IsPointerLocked() || contents->GetVisibility() != content::Visibility::VISIBLE)
    return false;
  // Remove a previous native popup before replacing it with host UI.
  if (auto* client = autofill::ContentAutofillClient::FromWebContents(contents))
    client->HideSuggestions(autofill::SuggestionHidingReason::kHiddenByCaller, std::nullopt);
  PasswordRows::CreateForWebContents(contents);
  return PasswordRows::FromWebContents(contents)->Show(args, delegate);
}

void HideHostPasswordSuggestions(content::WebContents* contents) {
  if (contents) if (auto* rows = PasswordRows::FromWebContents(contents)) rows->Hide();
}

void TrackAutofillFocus(content::WebContents* contents) {
  autofill::g_airc_autofill_suggestions_shown = &ReportShown;
  auto* client =
      contents ? autofill::ContentAutofillClient::FromWebContents(contents) : nullptr;
  if (client && !FocusedField::FromWebContents(contents)) {
    FocusedField::CreateForWebContents(contents, client);
  }
}

bool ShowAutofillSuggestions(content::WebContents* contents, bool passwords) {
  if (!contents) {
    return false;
  }
  TrackAutofillFocus(contents);
  auto* focused = FocusedField::FromWebContents(contents);
  return focused &&
         focused->Trigger(passwords
                              ? AutofillSuggestionTriggerSource::kManualFallbackPasswords
                              : AutofillSuggestionTriggerSource::kFormControlElementClicked);
}

}

@implementation AircTab (PasswordSuggestions)
- (BOOL)acceptAutofillSuggestion:(NSInteger)index {
  auto* rows = _contents ? airc::PasswordRows::FromWebContents(_contents) : nullptr;
  return rows && rows->Accept(index);
}
- (void)hideAutofillSuggestions {
  airc::HideHostPasswordSuggestions(_contents);
}
@end

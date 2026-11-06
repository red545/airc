// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_AUTOFILL_TRIGGER_H_
#define AIRC_CORE_AIRC_AUTOFILL_TRIGGER_H_

#include "base/memory/weak_ptr.h"
#include "components/autofill/core/browser/foundations/autofill_client.h"
#include "components/autofill/core/browser/ui/autofill_suggestion_delegate.h"

namespace content {
class WebContents;
}

namespace airc {

bool HostPasswordSuggestions(content::WebContents* contents,
    const autofill::AutofillClient::PopupOpenArgs& args,
    base::WeakPtr<autofill::AutofillSuggestionDelegate> delegate);
void HideHostPasswordSuggestions(content::WebContents* contents);
void TrackAutofillFocus(content::WebContents* contents);
bool ShowAutofillSuggestions(content::WebContents* contents, bool passwords);

}

#endif

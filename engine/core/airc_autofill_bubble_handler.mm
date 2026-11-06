// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_browser_window.h"

#include "chrome/browser/ui/autofill/save_address_bubble_controller.h"
#include "chrome/browser/ui/autofill/update_address_bubble_controller.h"
#include "content/public/browser/web_contents.h"
#include "airc/core/airc_autofill_prompt.h"

namespace airc {

AircAutofillBubbleHandler::AircAutofillBubbleHandler() = default;
AircAutofillBubbleHandler::~AircAutofillBubbleHandler() = default;

#define AIRC_NO_BUBBLE(...) \
  {                       \
    return nullptr;       \
  }
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::ShowSaveCreditCardBubble(
    content::WebContents* web_contents,
    autofill::SaveCardBubbleController* controller,
    bool) {
  return ShowSaveCardPrompt(web_contents, controller);
}
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::ShowIbanBubble(
    content::WebContents* web_contents,
    autofill::IbanBubbleController*,
    bool,
    autofill::IbanBubbleType) {
  return SkipIbanBubble(web_contents);
}
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowOfferNotificationBubble(content::WebContents* web_contents,
                                autofill::OfferNotificationBubbleController*,
                                bool) {
  return SkipOfferNotification(web_contents);
}
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowSaveAutofillAiDataBubble(content::WebContents*,
                                 autofill::AutofillAiImportDataController*)
        AIRC_NO_BUBBLE()
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowAutofillAiLocalSaveNotification(
        content::WebContents*,
        autofill::AutofillAiImportDataController*) AIRC_NO_BUBBLE()
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowSaveAddressProfileBubble(
        content::WebContents* web_contents,
        std::unique_ptr<autofill::SaveAddressBubbleController> controller,
        bool) {
  return ShowSaveAddressPrompt(web_contents, std::move(controller));
}
#if BUILDFLAG(ENABLE_DICE_SUPPORT)
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::ShowAddressSignInPromo(
    content::WebContents* web_contents,
    const autofill::AutofillProfile&) {
  return SkipAddressSignInPromo(web_contents);
}
#endif
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowUpdateAddressProfileBubble(
        content::WebContents* web_contents,
        std::unique_ptr<autofill::UpdateAddressBubbleController> controller,
        bool) {
  return ShowUpdateAddressPrompt(web_contents, std::move(controller));
}
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowFilledCardInformationBubble(
        content::WebContents*,
        autofill::FilledCardInformationBubbleController*,
        bool) AIRC_NO_BUBBLE()
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowVirtualCardEnrollBubble(content::WebContents*,
                                autofill::VirtualCardEnrollBubbleController*,
                                bool) AIRC_NO_BUBBLE()
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowVirtualCardEnrollConfirmationBubble(
        content::WebContents*,
        autofill::VirtualCardEnrollBubbleController*) AIRC_NO_BUBBLE()
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowMandatoryReauthBubble(content::WebContents*,
                              autofill::MandatoryReauthBubbleController*,
                              bool,
                              autofill::MandatoryReauthBubbleType)
        AIRC_NO_BUBBLE()
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowSaveCardConfirmationBubble(
        content::WebContents* web_contents,
        autofill::SaveCardBubbleController* controller) {
  return ShowSaveCardPrompt(web_contents, controller);
}
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowSaveIbanConfirmationBubble(content::WebContents*,
                                   autofill::IbanBubbleController*)
        AIRC_NO_BUBBLE()
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowOmniboxAutofillBubble(content::WebContents*,
                              autofill::OmniboxAutofillBubbleController*)
        AIRC_NO_BUBBLE()
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowPaymentsChurnedUsersBubble(
        content::WebContents*,
        autofill::PaymentsChurnedUsersBubbleController*,
        bool) AIRC_NO_BUBBLE()
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowPaymentsChurnedUsersConfirmationBubble(
        content::WebContents*,
        autofill::PaymentsChurnedUsersBubbleController*) AIRC_NO_BUBBLE()
autofill::AutofillBubbleBase* AircAutofillBubbleHandler::
    ShowWalletReminderNoticeBubble(
        content::WebContents*,
        autofill::WalletReminderNoticeBubbleController*,
        bool) AIRC_NO_BUBBLE()
#undef AIRC_NO_BUBBLE

}

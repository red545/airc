# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""The external Google CDM may be loaded only by Chromium's utility helper."""
from pathlib import PurePath
import re

LIBRARY_VALIDATION = 'com.apple.security.cs.disable-library-validation'
CDM_HELPERS = ('Airc Helper.app', 'Airc Helper (Aperitif).app')

def is_cdm_helper_bundle(relative):
    parts = PurePath(relative).parts
    return (len(parts) == 7 and parts[:4] ==
            ('Contents', 'Frameworks', 'Airc Framework.framework', 'Versions')
            and re.fullmatch(r'\d+\.\d+\.\d+\.\d+', parts[4]) is not None
            and parts[5] == 'Helpers' and parts[6] in CDM_HELPERS)

def is_cdm_helper_executable(relative):
    p = PurePath(relative)
    return (is_cdm_helper_bundle(p.parent.parent.parent)
            and p.parts[-3:-1] == ('Contents', 'MacOS')
            and p.name + '.app' == p.parent.parent.parent.name)

def library_validation_error(relative, entitlements):
    allowed = is_cdm_helper_executable(relative)
    disabled = entitlements.get(LIBRARY_VALIDATION) is True
    if disabled and not allowed:
        return 'library validation disabled outside the CDM utility helper'
    if allowed and not disabled:
        return 'CDM utility helper missing its library-validation exception'
    return None

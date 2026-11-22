# Prompt: The privacy page says what the app connects to

**File**: pdd/prompts/features/cloud-connect/288-privacy-page-connections.md
**Created**: 2026-11-22
**Project type**: Docs (`docs/privacy-policy.html`, `docs/privacy-policy.md`)
**Chain**: follow-up to prompt 280

## Problem

"No servers" read more absolutely than what the app does: it downloads content files, loads a
product page for the Wardrobe price check, and syncs a shared household between phones.

## Change

New section "What the app connects to" in both copies: content files from the project's GitHub
Pages site (lineups, exercise photos, the climb catalog, the climb-generator model), the product
page the person asks about, other phones in a shared household over local Wi-Fi, and links that
open in the browser. The Bluetooth line now names boards and training devices, and a Local network
line is added. Last updated: November 22, 2026.

## Checked against the code

Every `URLSession` user and every host in the app sources; `HouseholdPeerService` (Bonjour + TCP,
local network only).

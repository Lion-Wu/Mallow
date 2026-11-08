#!/bin/sh
set -eu

# Allow dependency macros to run in the noninteractive Xcode Cloud environment.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

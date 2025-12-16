#!/bin/bash

# BAT_THEME
x=$(defaults read .GlobalPreferences AppleInterfaceStyle 2>/dev/null) # Macos
if [[ $x = "Dark" ]]; then
	export BAT_THEME=$BAT_THEME_DARK
	export FZF_DEFAULT_OPTS=$FLEXOKI_DARK
else
	export BAT_THEME=$BAT_THEME_LIGHT
	export FZF_DEFAULT_OPTS=$FLEXOKI_LIGHT
fi

exec delta --syntax-theme="$BAT_THEME" "$@"

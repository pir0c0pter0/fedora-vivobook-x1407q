savedcmd_vivobook_color_ctrl.mod := printf '%s\n'   vivobook_color_ctrl.o | awk '!x[$$0]++ { print("./"$$0) }' > vivobook_color_ctrl.mod

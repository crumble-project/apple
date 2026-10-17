package main

import (
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
)

// These helpers draw System Settings' grouped style: titled sections of rounded rows,
// labels on the left and borderless controls on the right, hairlines between rows.

func section(c *ui.Context, title, footer string, rows ...func()) {
	theme := c.Theme()
	ui.Column(c).Gap(6).Children(func() {
		if title != "" {
			ui.Text(c, title).FontSize(13).Bold().Padding(0, 4)
		}
		ui.Column(c).Radius(10).Background(theme.Surface).BorderWidth(1).BorderColor(theme.Border.Alpha(0.6)).Clip().Children(func() {
			for i, row := range rows {
				if i > 0 {
					ui.Box(c).Height(1).Margin(0, 12).Background(theme.Border.Alpha(0.6))
				}
				row()
			}
		})
		if footer != "" {
			ui.Text(c, footer).FontSize(11).TextColor(theme.TextMuted).Padding(0, 4)
		}
	})
}

func settingsRow(c *ui.Context, label string, control func()) {
	ui.Row(c).MinHeight(36).Padding(6, 12).Gap(12).AlignItems(ui.Center).Children(func() {
		ui.Text(c, label).FontSize(13).Shrink(0)
		ui.Spacer(c)
		control()
	})
}

// textValue is a borderless, right-aligned field, as grouped forms edit text in place.
func textValue(c *ui.Context, value *string, label, placeholder string) ui.Element {
	return ui.TextInputBase(c.Key(label), value).TextAlign(ui.End).FontSize(13).Grow(1).MinWidth(160).MaxWidth(360).
		Label(label).Placeholder(placeholder)
}

// popupButton is a borderless pop-up button: the value with a chevron, opening a menu.
func popupButton(c *ui.Context, key string, value *string, options []string) bool {
	theme := c.Theme()
	before := *value
	sel := ui.SelectBase(c.Key(key), value)
	sel.Trigger.Gap(4).Padding(3, 4, 3, 8).Radius(6).AlignItems(ui.Center).Label(key)
	if sel.Trigger.Hovered() || sel.Open() {
		sel.Trigger.Background(theme.SurfaceHover)
	}
	sel.Trigger.Children(func() {
		ui.Text(c, *value).FontSize(13).TextColor(theme.TextMuted)
		symbol(c, "chevron.up.chevron.down", 9, theme.TextMuted)
	})
	sel.Popup(func(panel ui.Element) {
		menuPanel(c, panel, func() {
			for _, option := range options {
				menuItem(c, sel.Item(option), option, option == *value)
			}
		})
	})
	return *value != before
}

// modelField edits a model ID in place and suggests the provider's models below it.
func modelField(c *ui.Context, value *string, options []string) {
	theme := c.Theme()
	combo := ui.ComboboxBase(c.Key("model"), value)
	combo.Input.TextAlign(ui.End).FontSize(13).Grow(1).MinWidth(160).MaxWidth(360).Label("Model").Placeholder("Model ID")
	query := strings.ToLower(strings.TrimSpace(*value))
	combo.Popup(func(panel ui.Element) {
		menuPanel(c, panel, func() {
			shown := 0
			for _, option := range options {
				if combo.Filtering() && query != "" && !strings.Contains(strings.ToLower(option), query) {
					continue
				}
				menuItem(c, combo.Item(option), option, option == *value)
				shown++
			}
			if shown == 0 {
				ui.Text(c, "No matching models").FontSize(12).TextColor(theme.TextMuted).Padding(6, 10)
			}
		})
	})
	if chosen, ok := combo.Chosen(); ok {
		*value = chosen
	}
}

func menuPanel(c *ui.Context, panel ui.Element, items func()) {
	theme := c.Theme()
	panel.Margin(4, 0, 0, 0).Padding(5).Radius(10).MaxHeight(280).MinWidth(200).Background(theme.Surface).
		BorderWidth(1).BorderColor(theme.Border).Shadow(0, 8, 24, 0, ui.RGBA(0, 0, 0, 0.25)).Children(func() {
		ui.Scroll(c).Children(func() { ui.Column(c).Children(items) })
	})
}

func menuItem(c *ui.Context, item ui.Element, label string, chosen bool) {
	theme := c.Theme()
	color := theme.Text
	item.Padding(4, 10).Radius(5).Gap(6).AlignItems(ui.Center)
	if item.Highlighted() {
		item.Background(theme.Accent)
		color = theme.AccentText
	}
	item.Children(func() {
		if chosen {
			symbol(c, "checkmark", 10, color)
		} else {
			ui.Box(c).Size(10, 10)
		}
		ui.Text(c, label).FontSize(13).TextColor(color).SingleLine()
	})
}

// miniSwitch is the small switch System Settings puts at the end of a row.
func miniSwitch(c *ui.Context, on *bool, label string) ui.Element {
	theme := c.Theme()
	track := ui.SwitchBase(c.Key(label), on).Size(32, 18).Radius(9).Padding(2).Label(label)
	shown := track.Animate("on", b2f(*on), 150*time.Millisecond)
	track.Background(theme.Border.Mix(theme.Accent, shown))
	track.Children(func() {
		ui.Box(c).Size(14, 14).Radius(7).Background(ui.RGB(255, 255, 255)).Margin(0, 0, 0, 14*shown).
			Shadow(0, 1, 2, 0, ui.RGBA(0, 0, 0, 0.25))
	})
	return track
}

func b2f(v bool) float32 {
	if v {
		return 1
	}
	return 0
}

// rowButton is a row-wide button in a section, as "Add Skill…" in a grouped list.
func rowButton(c *ui.Context, key, label string, destructive bool) bool {
	theme := c.Theme()
	color := theme.Accent
	if destructive {
		color = theme.Danger
	}
	button := ui.ButtonBase(c.Key(key)).MinHeight(36).Padding(6, 12).Label(label)
	if button.Hovered() {
		button.Background(theme.SurfaceHover)
	}
	button.Children(func() { ui.Text(c, label).FontSize(13).TextColor(color) })
	return button.Clicked()
}

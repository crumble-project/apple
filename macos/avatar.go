package main

import (
	"container/list"
	"fmt"
	"strings"
	"sync"

	dicebear "github.com/dicebear/dicebear-go/v10"
	"github.com/dicebear/styles/v10"
	"github.com/egoist/mygo/ui"
)

const critterCacheLimit = 128

type critterCacheEntry struct {
	seed string
	svg  *ui.SVG
}

var critterState = struct {
	sync.Mutex
	style    *dicebear.Style
	styleErr error
	values   map[string]*list.Element
	order    *list.List
}{values: map[string]*list.Element{}, order: list.New()}

func critterStyle() (*dicebear.Style, error) {
	critterState.Lock()
	defer critterState.Unlock()
	if critterState.style != nil || critterState.styleErr != nil {
		return critterState.style, critterState.styleErr
	}
	critterState.style, critterState.styleErr = dicebear.NewStyle([]byte(styles.Critters))
	return critterState.style, critterState.styleErr
}

func critterSVGMarkup(seed string) (string, error) {
	style, err := critterStyle()
	if err != nil {
		return "", err
	}
	avatar, err := dicebear.NewAvatar(style, map[string]any{"seed": seed, "idRandomization": false})
	if err != nil {
		return "", err
	}
	return avatar.SVG(), nil
}

func critterSVG(seed string) (*ui.SVG, error) {
	if strings.TrimSpace(seed) == "" {
		return nil, fmt.Errorf("critter avatar seed is empty")
	}
	critterState.Lock()
	if element := critterState.values[seed]; element != nil {
		value := element.Value.(*critterCacheEntry)
		critterState.order.MoveToFront(element)
		critterState.Unlock()
		return value.svg, nil
	}
	critterState.Unlock()

	markup, err := critterSVGMarkup(seed)
	if err != nil {
		return nil, err
	}
	parsed, err := ui.ParseSVG([]byte(markup))
	if err != nil {
		return nil, err
	}

	critterState.Lock()
	if element := critterState.values[seed]; element != nil {
		value := element.Value.(*critterCacheEntry)
		critterState.order.MoveToFront(element)
		critterState.Unlock()
		return value.svg, nil
	}
	element := critterState.order.PushFront(&critterCacheEntry{seed: seed, svg: parsed})
	critterState.values[seed] = element
	for critterState.order.Len() > critterCacheLimit {
		oldest := critterState.order.Back()
		value := oldest.Value.(*critterCacheEntry)
		delete(critterState.values, value.seed)
		critterState.order.Remove(oldest)
	}
	critterState.Unlock()
	return parsed, nil
}

func agentAvatarSeed(agent Agent) string {
	if strings.HasPrefix(agent.Avatar, "critters:") {
		if seed := strings.TrimSpace(strings.TrimPrefix(agent.Avatar, "critters:")); seed != "" {
			return seed
		}
	}
	if strings.TrimSpace(agent.ID) != "" {
		return agent.ID
	}
	return "crumble"
}

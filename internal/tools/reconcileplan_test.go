package tools

import (
	"reflect"
	"testing"

	"github.com/mboersma/imogen/internal/k8s"
)

func TestDiffFlavor(t *testing.T) {
	releases := []k8s.Release{
		{Minor: "1.36", Version: "v1.36.2"},
		{Minor: "1.35", Version: "v1.35.6"},
		{Minor: "1.34", Version: "v1.34.9"},
	}

	tests := []struct {
		name      string
		staging   map[string]bool
		community map[string]bool
		want      []reconcileWorkItem
	}{
		{
			name:      "all present",
			community: map[string]bool{"1.36.2": true, "1.35.6": true, "1.34.9": true},
			want:      nil,
		},
		{
			name:      "missing everywhere needs build",
			staging:   map[string]bool{},
			community: map[string]bool{},
			want: []reconcileWorkItem{
				{Flavor: "ubuntu-2604", Version: "1.36.2", Minor: "1.36", Action: "build"},
				{Flavor: "ubuntu-2604", Version: "1.35.6", Minor: "1.35", Action: "build"},
				{Flavor: "ubuntu-2604", Version: "1.34.9", Minor: "1.34", Action: "build"},
			},
		},
		{
			name:      "staged but not promoted needs validate-promote",
			staging:   map[string]bool{"1.35.6": true},
			community: map[string]bool{"1.36.2": true},
			want: []reconcileWorkItem{
				{Flavor: "ubuntu-2604", Version: "1.35.6", Minor: "1.35", Action: "validate-promote"},
				{Flavor: "ubuntu-2604", Version: "1.34.9", Minor: "1.34", Action: "build"},
			},
		},
		{
			name:      "community version with v prefix is matched",
			community: map[string]bool{"1.36.2": true, "1.35.6": true, "1.34.9": true},
			want:      nil,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := diffFlavor("ubuntu-2604", releases, tc.staging, tc.community)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("diffFlavor() = %+v, want %+v", got, tc.want)
			}
		})
	}
}

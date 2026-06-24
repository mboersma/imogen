package k8s

import (
	"reflect"
	"testing"
)

func TestParseMinor(t *testing.T) {
	cases := []struct {
		in      string
		want    int
		wantErr bool
	}{
		{"v1.34.1", 34, false},
		{" v1.31.10\n", 31, false},
		{"1.28.0", 28, false},
		{"v1", 0, true},
		{"garbage", 0, true},
	}
	for _, c := range cases {
		got, err := parseMinor(c.in)
		if c.wantErr {
			if err == nil {
				t.Errorf("parseMinor(%q): expected error", c.in)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseMinor(%q): unexpected error %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("parseMinor(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestRecentMinors(t *testing.T) {
	cases := []struct {
		latest, n int
		want      []int
	}{
		{34, 3, []int{34, 33, 32}},
		{34, 1, []int{34}},
		{1, 3, []int{1, 0}},
		{34, 0, []int{}},
	}
	for _, c := range cases {
		got := recentMinors(c.latest, c.n)
		if len(got) == 0 && len(c.want) == 0 {
			continue
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("recentMinors(%d, %d) = %v, want %v", c.latest, c.n, got, c.want)
		}
	}
}

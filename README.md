# Musly DSTM Mixer

LMS `Don't Stop The Music` mixer using [Musly API Server](https://github.com/CDrummond/musly-server)

Genres are configured via editing `genres.json` using the following syntax:

```
[
 [ "Rock", "Hard Rock", "Metal" ],
 [ "Pop", "Dance", "R&B"]
]
```

If a seed track has `Hard Rock` as its genre, then only tracks with `Rock`, 
`Hard Rock`, or `Metal` will be allowed. If a seed track has a genre that is not
listed here then any track returned by Musly will be considered acceptable.

`genres.json` should be placed within you LMS's `prefs` folder. If this is not
found there, then the plugin will use its own version.

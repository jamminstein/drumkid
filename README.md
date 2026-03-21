# drumkid

aleatoric drum machine for monome norns, powered by synthesised drums.

## requirements

- monome norns
- [supertonic](https://github.com/schollz/supertonic) script installed (provides the Supertonic synthesis engine)
- grid optional (16x8 or 8x8)

## install

from maiden:
```
;install https://github.com/jamminstein/drumkid
```

make sure you also have supertonic installed:
```
;install https://github.com/schollz/supertonic
```

## controls

- **E1** tempo (BPM)
- **E2** browse parameters
- **E3** adjust selected parameter
- **K2** play / stop (release to confirm)
- **K3 short** randomise pattern
- **K3 long** randomise pattern + all params
- **K2+K3** randomise selected param
- **grid** toggle steps (rows 1-4 = kick/snare/hat/open)

## voices

four synthesised drum voices via the Supertonic engine:

1. **kick** — sine oscillator with pitch-drop modulation
2. **snare** — oscillator + high-pass filtered noise
3. **closed hat** — tight noise burst, high-pass filtered
4. **open hat** — longer noise tail, band-pass filtered

## parameters

| param | effect |
|-------|--------|
| chance | probability of aleatoric hits |
| zoom | density of active steps |
| midpoint | center of the active zone |
| range | width of the active zone |
| pitch | tune all voices up/down |
| crush | distortion amount |
| crop | envelope length (shorter = tighter) |
| drop | mute/solo voice combinations |
| velocity | humanise hit levels |
| subdiv | half-time / normal / double-time+swing |
| warmth | low-pass filter darkness |
| reverb | reverb send level |
| prob_amt | scale per-step probability |
| swing | shuffle even 16ths |
| midi_ch_k/s/h | MIDI output channels |

## credits

inspired by [mattybrad/drumkid](https://github.com/mattybrad/drumkid).  
supertonic engine by [schollz](https://github.com/schollz/supertonic).

module main

import stbi
import math
import flag
import os

struct RGB {
	r u8
	g u8
	b u8
}

struct RawImage {
	width    int
	height   int
	channels int
mut:
	data []u8
}

struct WorkerResult {
	candidate string
	error     f64
	best_x    int
	best_y    int
}

struct BeamCandidate {
	text  string
	error f64
}

type DegradationFn = fn (RawImage, int) RawImage

fn main() {
	if os.args.len > 1 && os.args[1] == 'test' {
		mut custom_font := ''
		mut rtl := false
		for arg in os.args[2..] {
			if arg == '-rtl' || arg == '--rtl' {
				rtl = true
			} else if !arg.starts_with('-') {
				custom_font = arg
			}
		}
		run_self_tests(custom_font, rtl)
		return
	}

	mut fp := flag.new_flag_parser(os.args)
	fp.application('pixviper')
	fp.version('2.4.5')
	fp.description('Parallel Template Matching and De-redaction Tool.')

	target_path := fp.string('image', `i`, 'target.png', 'Path to the target image')
	mode := fp.string('mode', `m`, 'pixelate', 'Degradation mode: "pixelate" or "blur"')
	intensity := fp.int('intensity', `s`, 8, 'Intensity parameter')
	bg_color_hex := fp.string('bg-color', `b`, 'FFFFFF', 'Background color in hex (RRGGBB)')
	text_color_hex := fp.string('text-color', `t`, '000000', 'Text color in hex (RRGGBB)')
	bg_image_path := fp.string('bg-image', `g`, '', 'Optional background image path')
	font_path := fp.string('font', `f`, '', 'Optional path to .ttf/.otf font file')
	alphabet := fp.string('alphabet', `a`, 'abcdefghijklmnopqrstuvwxyz0123456789', 'Custom alphabet map for letter-by-letter search')
	length := fp.int('length', `l`, 8, 'Target length for the text recovery')
	mask_path := fp.string('mask', `k`, '', 'Optional path to alpha mask image (same size as target)')
	seq_decode := fp.bool('seq', `q`, true, 'Enable sequential character-by-character decoding (default: true)')
	gif_flag := fp.bool('gif', `\0`, false, 'Generate an animated GIF of the trial-and-error process')
	rtl := fp.bool('rtl', `r`, false, 'Enable Right-to-Left (RTL) mode for Arabic/Persian text')

	fp.finalize() or {
		println(fp.usage())
		return
	}

	if font_path != '' && !os.exists(font_path) {
		eprintln('Warning: Font file not found at "${font_path}".')
	}

	println('Starting Pixviper template matching engine...')
	println('Target image path: ${target_path}')
	println('Selected mode: ${mode}')
	println('Intensity: ${intensity}')
	
	if seq_decode {
		println('Method: Character-by-Character Sequential Search (No Dictionary)')
		println('Search alphabet: "${alphabet}"')
		println('Target length: ${length}')
	} else {
		println('Method: Candidate Dictionary Matching')
	}

	if gif_flag {
		println('GIF recording enabled. Results will be saved to pixviper_process.gif')
	}

	target_img := stbi.load(target_path) or {
		eprintln('Failed to load target image: ' + err.msg())
		return
	}

	target := RawImage{
		width: target_img.width
		height: target_img.height
		channels: target_img.nr_channels
		data: unsafe { target_img.data.vbytes(target_img.width * target_img.height * target_img.nr_channels) }
	}

	bg_color := hex_to_rgb(bg_color_hex)
	text_color := hex_to_rgb(text_color_hex)

	mut bg_img := RawImage{}
	if bg_image_path != '' {
		println('Loading background image: ${bg_image_path}')
		loaded_bg := stbi.load(bg_image_path) or {
			eprintln('Failed to load background image. Falling back to solid color.')
			stbi.Image{}
		}
		if loaded_bg.width > 0 {
			bg_img = RawImage{
				width: loaded_bg.width
				height: loaded_bg.height
				channels: loaded_bg.nr_channels
				data: unsafe { loaded_bg.data.vbytes(loaded_bg.width * loaded_bg.height * loaded_bg.nr_channels) }
			}
		}
	}

	mut mask := RawImage{}
	if mask_path != '' {
		println('Loading mask image: ${mask_path}')
		loaded_mask := stbi.load(mask_path) or {
			eprintln('Failed to load mask image. Falling back to no-mask.')
			stbi.Image{}
		}
		if loaded_mask.width > 0 {
			mask = RawImage{
				width: loaded_mask.width
				height: loaded_mask.height
				channels: loaded_mask.nr_channels
				data: unsafe { loaded_mask.data.vbytes(loaded_mask.width * loaded_mask.height * loaded_mask.nr_channels) }
			}
		}
	}

	if seq_decode {
		if alphabet == '' || length <= 0 {
			eprintln('Sequential decoding requires non-empty --alphabet and --length > 0.')
			return
		}
		result := decode_sequential(target, mode, intensity, alphabet, length, bg_color, text_color, bg_img, font_path, bg_color_hex, text_color_hex, gif_flag, 'pixviper_process.gif', rtl)
		println('Final Decoded Text: ${result}')
		return
	}

	mut candidates := []string{}
	if alphabet != '' && length > 0 {
		println('Generating candidate list from custom alphabet: ${alphabet} with length: ${length}')
		candidates = generate_candidates(alphabet, length)
		println('Generated ${candidates.len} candidate strings.')
	} else {
		candidates = ['admin', 'password', 'secret123', 'root', 'user', 'system']
	}

	best_match, lowest_error, bx, by := find_best_match(target, mode, intensity, candidates, bg_color, text_color, bg_img, font_path, bg_color_hex, text_color_hex, mask, gif_flag, 'pixviper_process.gif', rtl)

	println('Analysis finished.')
	println('Identified text: ${best_match} | Best Location: (x: ${bx}, y: ${by}) | Final MAE: ${lowest_error}')
}

fn find_anchor_position(target RawImage, mode string, intensity int, target_length int, bg_color RGB, text_color RGB, _bg_img RawImage, font_path string, bg_color_hex string, text_color_hex string, rtl bool) (int, int) {
	mut dummy := ''
	for _ in 0 .. target_length {
		dummy += 'a'
	}
	
	char_width := 5
	gap := 2
	margin_x := 8
	margin_y := 8
	temp_w := dummy.runes().len * (char_width + gap) - gap + (margin_x * 2)
	temp_h := 5 + (margin_y * 2)

	mut rendered := RawImage{}
	if font_path != '' {
		rendered = render_text_with_font(dummy, font_path, bg_color_hex, text_color_hex, temp_w, temp_h, rtl) or {
			mock_render_text(dummy, temp_w, temp_h, target.channels, bg_color, text_color, RawImage{}, margin_x, margin_y)
		}
	} else {
		rendered = mock_render_text(dummy, temp_w, temp_h, target.channels, bg_color, text_color, RawImage{}, margin_x, margin_y)
	}

	mut degradation_algo := custom_pixelator
	if mode == 'blur' {
		degradation_algo = custom_blur
	}
	processed := degradation_algo(rendered, intensity)
	
	_, bx, by := calculate_sliding_mae_masked(target, processed, RawImage{})
	return bx, by
}

fn calculate_mae_at_pos(target RawImage, template RawImage, tx int, ty int, mask RawImage, limit_x int, rtl bool) f64 {
	if tx < 0 || ty < 0 || tx + template.width > target.width || ty + template.height > target.height {
		return math.max_f64
	}
	
	mut sum := 0.0
	mut weight_sum := 0.0
	has_mask := mask.data.len == target.data.len && mask.width == target.width && mask.height == target.height

	for y := 0; y < template.height; y++ {
		for x := 0; x < template.width; x++ {
			if limit_x >= 0 {
				if rtl {
					if x < limit_x {
						continue
					}
				} else {
					if x > limit_x {
						continue
					}
				}
			}

			idx_temp := (y * template.width + x) * template.channels
			idx_target := ((ty + y) * target.width + (tx + x)) * target.channels

			mut weight := 1.0
			if has_mask {
				mask_val := mask.data[idx_target]
				alpha := f64(mask_val) / 255.0
				weight = 1.0 - alpha
			}

			if weight <= 0.0 {
				continue
			}

			diff_r := math.abs(f64(target.data[idx_target]) - f64(template.data[idx_temp]))
			diff_g := math.abs(f64(target.data[idx_target + 1]) - f64(template.data[idx_temp + 1]))
			diff_b := math.abs(f64(target.data[idx_target + 2]) - f64(template.data[idx_temp + 2]))

			sum += weight * (diff_r + diff_g + diff_b)
			weight_sum += weight * 3.0
		}
	}

	if weight_sum > 0.0 {
		return sum / weight_sum
	}
	return math.max_f64
}

fn decode_sequential(target RawImage, mode string, intensity int, alphabet string, target_length int, bg_color RGB, text_color RGB, bg_img RawImage, font_path string, bg_color_hex string, text_color_hex string, generate_gif bool, output_gif_path string, rtl bool) string {
	runes := alphabet.runes()
	mut beams := ['']
	beam_width := 10
	empty_bg := RawImage{}
	mut frame_idx := 0

	println('Detecting redaction anchor position...')
	start_x, start_y := find_anchor_position(target, mode, intensity, target_length, bg_color, text_color, bg_img, font_path, bg_color_hex, text_color_hex, rtl)
	println('Anchor locked at template top-left (x: ${start_x}, y: ${start_y})')

	render_margin_x := start_x + 8
	render_margin_y := start_y + 8

	for step := 0; step < target_length; step++ {
		println('Decoding position ${step + 1}/${target_length} using Beam Search...')
		mut pool := []BeamCandidate{}
		mut limit_x := -1
		if font_path != '' {
			if rtl {
				limit_x = target.width - 8 - (step + 1) * 10
			} else {
				limit_x = 8 + (step + 1) * 10
			}
		}

		for beam in beams {
			for r in runes {
				candidate := beam + r.str()

				mut rendered := RawImage{}
				if font_path != '' {
					rendered = render_text_with_font(candidate, font_path, bg_color_hex, text_color_hex, target.width, target.height, rtl) or {
						mock_render_text(candidate, target.width, target.height, target.channels, bg_color, text_color, bg_img, render_margin_x, render_margin_y)
					}
				} else {
					rendered = mock_render_text(candidate, target.width, target.height, target.channels, bg_color, text_color, bg_img, render_margin_x, render_margin_y)
				}
				
				mut degradation_algo := custom_pixelator
				if mode == 'blur' {
					degradation_algo = custom_blur
				}
				processed := degradation_algo(rendered, intensity)
				
				mut lowest_jitter_error := math.max_f64
				for dy := -1; dy <= 1; dy++ {
					for dx := -1; dx <= 1; dx++ {
						err := calculate_mae_at_pos(target, processed, dx, dy, empty_bg, limit_x, rtl)
						if err < lowest_jitter_error {
							lowest_jitter_error = err
						}
					}
				}

				pool << BeamCandidate{
					text: candidate
					error: lowest_jitter_error
				}
			}
		}

		pool.sort(a.error < b.error)

		beams.clear()
		mut limit := beam_width
		if pool.len < beam_width {
			limit = pool.len
		}
		for i := 0; i < limit; i++ {
			beams << pool[i].text
		}

		println('Top candidates in beam: ${beams}')

		if generate_gif && beams.len > 0 {
			best_current := beams[0]
			mut rendered := RawImage{}
			if font_path != '' {
				rendered = render_text_with_font(best_current, font_path, bg_color_hex, text_color_hex, target.width, target.height, rtl) or {
					mock_render_text(best_current, target.width, target.height, target.channels, bg_color, text_color, bg_img, render_margin_x, render_margin_y)
				}
			} else {
				rendered = mock_render_text(best_current, target.width, target.height, target.channels, bg_color, text_color, bg_img, render_margin_x, render_margin_y)
			}

			mut degradation_algo := custom_pixelator
			if mode == 'blur' {
				degradation_algo = custom_blur
			}
			processed := degradation_algo(rendered, intensity)

			side_by_side := create_side_by_side(target, processed)

			frame_filename := 'temp_frame_${frame_idx:03d}.png'
			stbi.stbi_write_png(frame_filename, side_by_side.width, side_by_side.height, side_by_side.channels, &side_by_side.data[0], side_by_side.width * side_by_side.channels) or {
				eprintln('Failed to write temp frame ${frame_filename}')
				continue
			}
			frame_idx++
		}
	}

	if generate_gif && frame_idx > 0 {
		success := compile_gif(frame_idx, 80, output_gif_path)
		if success {
			println('Successfully created animated GIF of the sequential decoding process at ${output_gif_path}')
		} else {
			eprintln('Failed to compile GIF.')
		}
		clean_temp_frames(frame_idx)
	}

	if beams.len > 0 {
		return beams[0]
	}
	return ''
}

fn generate_candidates(alphabet string, length int) []string {
	runes := alphabet.runes()
	mut result := []string{}
	mut current := []rune{len: length}
	generate_comb_recursive(runes, length, 0, mut current, mut result)
	return result
}

fn generate_comb_recursive(runes []rune, length int, depth int, mut current []rune, mut result []string) {
	if depth == length {
		result << current.string()
		return
	}
	for r in runes {
		current[depth] = r
		generate_comb_recursive(runes, length, depth + 1, mut current, mut result)
	}
}

fn run_self_tests(custom_font string, rtl bool) {
	println('=== Running Parallel Sliding Window Self-Tests ===')
	if custom_font != '' {
		println('Using custom font for self-tests: ${custom_font}')
		if !os.exists(custom_font) {
			println('Warning: Custom font file does not exist at "${custom_font}". Tests using this font may fail.')
		}
		if rtl {
			println('RTL mode is ENABLED.')
		}
	}
	candidates := ['admin', 'password', 'secret123', 'root', 'user', 'system']
	empty_bg := RawImage{}

	println('Running Test Case 1: Mode = pixelate, Intensity = 8, Target = secret123')
	tc1_bg := RGB{255, 255, 255}
	tc1_text := RGB{0, 0, 0}
	test_render_1 := mock_render_text('secret123', 120, 40, 3, tc1_bg, tc1_text, empty_bg, 32, 16)
	stbi.stbi_write_png('test_case_1_raw.png', test_render_1.width, test_render_1.height, test_render_1.channels, &test_render_1.data[0], test_render_1.width * test_render_1.channels) or {
		panic(err)
	}
	target_1 := custom_pixelator(test_render_1, 8)
	stbi.stbi_write_png('test_case_1_pixelated.png', target_1.width, target_1.height, target_1.channels, &target_1.data[0], target_1.width * target_1.channels) or {
		panic(err)
	}
	best_1, error_1, bx1, by1 := find_best_match(target_1, 'pixelate', 8, candidates, tc1_bg, tc1_text, empty_bg, '', 'FFFFFF', '000000', empty_bg, true, 'test_case_1_search.gif', false)
	if best_1 == 'secret123' && bx1 == 24 && by1 == 8 {
		println('Test Case 1: PASSED (Match: ${best_1} at x: ${bx1}, y: ${by1}, MAE: ${error_1})')
	} else {
		println('Test Case 1: FAILED (Expected secret123 at 24,8. Got: ${best_1} at ${bx1},${by1})')
	}

	println('Running Test Case 2: Mode = blur, Intensity = 3, Target = admin')
	tc2_bg := RGB{0, 0, 255}
	tc2_text := RGB{255, 255, 0}
	test_render_2 := mock_render_text('admin', 120, 40, 3, tc2_bg, tc2_text, empty_bg, 40, 12)
	stbi.stbi_write_png('test_case_2_raw.png', test_render_2.width, test_render_2.height, test_render_2.channels, &test_render_2.data[0], test_render_2.width * test_render_2.channels) or {
		panic(err)
	}
	target_2 := custom_blur(test_render_2, 3)
	stbi.stbi_write_png('test_case_2_blurred.png', target_2.width, target_2.height, target_2.channels, &target_2.data[0], target_2.width * target_2.channels) or {
		panic(err)
	}
	best_2, error_2, bx2, by2 := find_best_match(target_2, 'blur', 3, candidates, tc2_bg, tc2_text, empty_bg, '', '0000FF', 'FFFF00', empty_bg, true, 'test_case_2_search.gif', false)
	if best_2 == 'admin' && bx2 == 32 && by2 == 4 {
		println('Test Case 2: PASSED (Match: ${best_2} at x: ${bx2}, y: ${by2}, MAE: ${error_2})')
	} else {
		println('Test Case 2: FAILED (Expected admin at 32,4. Got: ${best_2} at ${bx2},${by2})')
	}

	println('Running Test Case 3: Dynamic Alphabet Permutation Verification')
	test_alphabet := '12'
	test_len := 2
	generated_combos := generate_candidates(test_alphabet, test_len)
	if generated_combos.len == 4 && '11' in generated_combos && '12' in generated_combos && '21' in generated_combos && '22' in generated_combos {
		println('Test Case 3: PASSED')
	} else {
		println('Test Case 3: FAILED')
	}

	println('Running Test Case 4: Masked Search (Scribble Occlusion)')
	tc4_bg := RGB{255, 255, 255}
	tc4_text := RGB{0, 0, 0}
	mut test_render_4 := mock_render_text('secret123', 120, 40, 3, tc4_bg, tc4_text, empty_bg, 32, 16)
	mut mask_data := []u8{len: 120 * 40 * 3}
	for y := 0; y < 40; y++ {
		for x := 0; x < 120; x++ {
			idx := (y * 120 + x) * 3
			if x >= 48 && x < 72 {
				mask_data[idx] = 255
				mask_data[idx + 1] = 255
				mask_data[idx + 2] = 255
			}
			if x >= 50 && x < 70 {
				test_render_4.data[idx] = 0
				test_render_4.data[idx + 1] = 0
				test_render_4.data[idx + 2] = 0
			}
		}
	}
	mask_img := RawImage{
		width: 120
		height: 40
		channels: 3
		data: mask_data
	}
	stbi.stbi_write_png('test_case_4_raw_occluded.png', test_render_4.width, test_render_4.height, test_render_4.channels, &test_render_4.data[0], test_render_4.width * test_render_4.channels) or {
		panic(err)
	}
	target_4 := custom_pixelator(test_render_4, 8)
	stbi.stbi_write_png('test_case_4_pixelated_occluded.png', target_4.width, target_4.height, target_4.channels, &target_4.data[0], target_4.width * target_4.channels) or {
		panic(err)
	}
	best_4, error_4, bx4, by4 := find_best_match(target_4, 'pixelate', 8, candidates, tc4_bg, tc4_text, empty_bg, '', 'FFFFFF', '000000', mask_img, true, 'test_case_4_search.gif', false)
	if best_4 == 'secret123' && bx4 == 24 && by4 == 8 {
		println('Test Case 4: PASSED (Match: ${best_4} with occlusion ignored, MAE: ${error_4})')
	} else {
		println('Test Case 4: FAILED (Expected secret123 at 24,8. Got: ${best_4} at ${bx4},${by4}, MAE: ${error_4})')
	}

	println('Running Test Case 5: Sequential Pixelate Search')
	tc5_bg := RGB{255, 255, 255}
	tc5_text := RGB{0, 0, 0}
	test_render_5 := mock_render_text('abc', 120, 40, 3, tc5_bg, tc5_text, empty_bg, 32, 16)
	stbi.stbi_write_png('test_case_5_raw.png', test_render_5.width, test_render_5.height, test_render_5.channels, &test_render_5.data[0], test_render_5.width * test_render_5.channels) or {
		panic(err)
	}
	target_5 := custom_pixelator(test_render_5, 4)
	stbi.stbi_write_png('test_case_5_pixelated.png', target_5.width, target_5.height, target_5.channels, &target_5.data[0], target_5.width * target_5.channels) or {
		panic(err)
	}
	best_5 := decode_sequential(target_5, 'pixelate', 4, 'abcdefg', 3, tc5_bg, tc5_text, empty_bg, '', 'FFFFFF', '000000', true, 'test_case_5_sequential.gif', false)
	if best_5 == 'abc' {
		println('Test Case 5: PASSED (Decoded: ${best_5})')
	} else {
		println('Test Case 5: FAILED (Expected "abc", got "${best_5}")')
	}

	println('Running Test Case 6: Sequential Blur Search')
	tc6_bg := RGB{255, 255, 255}
	tc6_text := RGB{0, 0, 0}
	test_render_6 := mock_render_text('de', 120, 40, 3, tc6_bg, tc6_text, empty_bg, 32, 16)
	stbi.stbi_write_png('test_case_6_raw.png', test_render_6.width, test_render_6.height, test_render_6.channels, &test_render_6.data[0], test_render_6.width * test_render_6.channels) or {
		panic(err)
	}
	target_6 := custom_blur(test_render_6, 2)
	stbi.stbi_write_png('test_case_6_blurred.png', target_6.width, target_6.height, target_6.channels, &target_6.data[0], target_6.width * target_6.channels) or {
		panic(err)
	}
	best_6 := decode_sequential(target_6, 'blur', 2, 'abcdefg', 2, tc6_bg, tc6_text, empty_bg, '', 'FFFFFF', '000000', true, 'test_case_6_sequential.gif', false)
	if best_6 == 'de' {
		println('Test Case 6: PASSED (Decoded: ${best_6})')
	} else {
		println('Test Case 6: FAILED (Expected "de", got "${best_6}")')
	}

	println('Running Test Case 7: Sequential Number Search')
	tc7_bg := RGB{255, 255, 255}
	tc7_text := RGB{0, 0, 0}
	test_render_7 := mock_render_text('123', 120, 40, 3, tc7_bg, tc7_text, empty_bg, 32, 16)
	stbi.stbi_write_png('test_case_7_raw.png', test_render_7.width, test_render_7.height, test_render_7.channels, &test_render_7.data[0], test_render_7.width * test_render_7.channels) or {
		panic(err)
	}
	target_7 := custom_pixelator(test_render_7, 4)
	stbi.stbi_write_png('test_case_7_pixelated.png', target_7.width, target_7.height, target_7.channels, &target_7.data[0], target_7.width * target_7.channels) or {
		panic(err)
	}
	best_7 := decode_sequential(target_7, 'pixelate', 4, '0123456789', 3, tc7_bg, tc7_text, empty_bg, '', 'FFFFFF', '000000', true, 'test_case_7_sequential.gif', false)
	if best_7 == '123' {
		println('Test Case 7: PASSED (Decoded: ${best_7})')
	} else {
		println('Test Case 7: FAILED (Expected "123", got "${best_7}")')
	}

	if custom_font != '' {
		tc8_bg := RGB{255, 255, 255}
		tc8_text := RGB{0, 0, 0}

		mut test_text := 'test'
		mut alphabet := 'est'
		mut target_len := 4
		mut test_desc := 'English LTR'

		if rtl {
			test_text = 'مرحبا'
			alphabet = 'امربح'
			target_len = 5
			test_desc = 'Arabic RTL'
		}

		println('Running Test Case 8: ${test_desc} script recovery using custom font')

		test_render_8 := render_text_with_font(test_text, custom_font, 'FFFFFF', '000000', 120, 40, rtl) or {
			RawImage{}
		}
		if test_render_8.width > 0 {
			stbi.stbi_write_png('test_case_8_raw.png', test_render_8.width, test_render_8.height, test_render_8.channels, &test_render_8.data[0], test_render_8.width * test_render_8.channels) or {
				panic(err)
			}
			target_8 := custom_pixelator(test_render_8, 4)
			stbi.stbi_write_png('test_case_8_pixelated.png', target_8.width, target_8.height, target_8.channels, &target_8.data[0], target_8.width * target_8.channels) or {
				panic(err)
			}
			best_8 := decode_sequential(target_8, 'pixelate', 4, alphabet, target_len, tc8_bg, tc8_text, empty_bg, custom_font, 'FFFFFF', '000000', true, 'test_case_8_sequential.gif', rtl)
			if best_8 == test_text {
				println('Test Case 8: PASSED (Decoded ${test_desc}: ${best_8})')
			} else {
				println('Test Case 8: FAILED (Expected "${test_text}", got "${best_8}")')
			}
		} else {
			println('Test Case 8: SKIPPED (Font rendering failed)')
		}
	} else {
		println('Running Test Case 8: SKIPPED (Requires custom font file)')
	}

	println('=== All Parallel Self-Tests Completed ===')
}

fn find_best_match(target RawImage, mode string, intensity int, candidates []string, bg_color RGB, text_color RGB, bg_img RawImage, font_path string, bg_color_hex string, text_color_hex string, mask RawImage, generate_gif bool, output_gif_path string, rtl bool) (string, f64, int, int) {
	mut threads := []thread WorkerResult{}

	for candidate in candidates {
		threads << spawn check_candidate(candidate, target, mode, intensity, bg_color, text_color, bg_img, font_path, bg_color_hex, text_color_hex, mask, rtl)
	}

	mut best_match := ''
	mut lowest_error := math.max_f64
	mut best_x := 0
	mut best_y := 0

	mut results := []WorkerResult{}

	for t in threads {
		res := t.wait()
		results << res
		println('Processed Candidate: ${res.candidate} | Min MAE: ${res.error} at (x: ${res.best_x}, y: ${res.best_y})')
		if res.error < lowest_error {
			lowest_error = res.error
			best_match = res.candidate
			best_x = res.best_x
			best_y = res.best_y
		}
	}

	if generate_gif {
		generate_gif_from_results(results, target, mode, intensity, bg_color, text_color, bg_img, font_path, bg_color_hex, text_color_hex, output_gif_path, rtl)
	}

	return best_match, lowest_error, best_x, best_y
}

fn check_candidate(candidate string, target RawImage, mode string, intensity int, bg_color RGB, text_color RGB, bg_img RawImage, font_path string, bg_color_hex string, text_color_hex string, mask RawImage, rtl bool) WorkerResult {
	mut degradation_algo := custom_pixelator
	if mode == 'blur' {
		degradation_algo = custom_blur
	}

	char_width := 5
	gap := 2
	margin_x := 8
	margin_y := 8

	runes := candidate.runes()
	temp_w := runes.len * (char_width + gap) - gap + (margin_x * 2)
	temp_h := 5 + (margin_y * 2)

	mut rendered := RawImage{}
	if font_path != '' {
		rendered = render_text_with_font(candidate, font_path, bg_color_hex, text_color_hex, temp_w, temp_h, rtl) or {
			mock_render_text(candidate, temp_w, temp_h, target.channels, bg_color, text_color, bg_img, margin_x, margin_y)
		}
	} else {
		rendered = mock_render_text(candidate, temp_w, temp_h, target.channels, bg_color, text_color, bg_img, margin_x, margin_y)
	}

	processed := degradation_algo(rendered, intensity)
	error, bx, by := calculate_sliding_mae_masked(target, processed, mask)

	return WorkerResult{
		candidate: candidate
		error: error
		best_x: bx
		best_y: by
	}
}

fn generate_gif_from_results(results []WorkerResult, target RawImage, mode string, intensity int, bg_color RGB, text_color RGB, bg_img RawImage, font_path string, bg_color_hex string, text_color_hex string, output_gif_path string, rtl bool) {
	println('Generating animated GIF representing search trials: ${output_gif_path}...')
	mut frame_idx := 0
	mut running_best_error := math.max_f64
	
	is_large := results.len > 50

	for i, res in results {
		mut should_render := false
		if !is_large {
			should_render = true
		} else {
			if i == 0 || i == results.len - 1 {
				should_render = true
			} else if res.error < running_best_error {
				should_render = true
				running_best_error = res.error
			}
		}

		if should_render {
			if res.error < running_best_error {
				running_best_error = res.error
			}

			char_width := 5
			gap := 2
			margin_x := 8
			margin_y := 8

			runes := res.candidate.runes()
			temp_w := runes.len * (char_width + gap) - gap + (margin_x * 2)
			temp_h := 5 + (margin_y * 2)

			mut rendered := RawImage{}
			if font_path != '' {
				rendered = render_text_with_font(res.candidate, font_path, bg_color_hex, text_color_hex, temp_w, temp_h, rtl) or {
					mock_render_text(res.candidate, temp_w, temp_h, target.channels, bg_color, text_color, bg_img, margin_x, margin_y)
				}
			} else {
				rendered = mock_render_text(res.candidate, temp_w, temp_h, target.channels, bg_color, text_color, bg_img, margin_x, margin_y)
			}

			mut degradation_algo := custom_pixelator
			if mode == 'blur' {
				degradation_algo = custom_blur
			}
			processed := degradation_algo(rendered, intensity)

			recon := create_reconstructed_image(target, processed, res.best_x, res.best_y, bg_color, bg_img, mode, intensity)
			side_by_side := create_side_by_side(target, recon)

			frame_filename := 'temp_frame_${frame_idx:03d}.png'
			stbi.stbi_write_png(frame_filename, side_by_side.width, side_by_side.height, side_by_side.channels, &side_by_side.data[0], side_by_side.width * side_by_side.channels) or {
				eprintln('Failed to write temp frame ${frame_filename}')
				continue
			}
			frame_idx++
		}
	}

	if frame_idx > 0 {
		success := compile_gif(frame_idx, 60, output_gif_path)
		if success {
			println('Successfully created animated GIF at ${output_gif_path}')
		} else {
			eprintln('Failed to compile GIF.')
		}
		clean_temp_frames(frame_idx)
	}
}

fn create_reconstructed_image(target RawImage, template RawImage, bx int, by int, bg_color RGB, bg_img RawImage, mode string, intensity int) RawImage {
	mut canvas := RawImage{
		width: target.width
		height: target.height
		channels: target.channels
		data: []u8{len: target.width * target.height * target.channels}
	}
	
	if bg_img.data.len == canvas.data.len {
		for i in 0 .. canvas.data.len {
			canvas.data[i] = bg_img.data[i]
		}
	} else {
		for i := 0; i < canvas.data.len; i += canvas.channels {
			canvas.data[i] = bg_color.r
			if canvas.channels > 1 {
				canvas.data[i + 1] = bg_color.g
			}
			if canvas.channels > 2 {
				canvas.data[i + 2] = bg_color.b
			}
			if canvas.channels == 4 {
				canvas.data[i + 3] = 255
			}
		}
	}
	
	mut degraded_canvas := canvas
	mut degradation_algo := custom_pixelator
	if mode == 'blur' {
		degradation_algo = custom_blur
	}
	degraded_canvas = degradation_algo(canvas, intensity)

	for y := 0; y < template.height; y++ {
		canvas_y := by + y
		if canvas_y < 0 || canvas_y >= target.height {
			continue
		}
		for x := 0; x < template.width; x++ {
			canvas_x := bx + x
			if canvas_x < 0 || canvas_x >= target.width {
				continue
			}
			
			template_idx := (y * template.width + x) * template.channels
			canvas_idx := (canvas_y * target.width + canvas_x) * target.channels
			
			for c := 0; c < target.channels; c++ {
				if canvas_idx + c < degraded_canvas.data.len && template_idx + c < template.data.len {
					degraded_canvas.data[canvas_idx + c] = template.data[template_idx + c]
				}
			}
		}
	}
	
	return degraded_canvas
}

fn create_side_by_side(target RawImage, reconstruction RawImage) RawImage {
	divider_width := 10
	out_width := target.width * 2 + divider_width
	out_height := target.height
	channels := target.channels
	
	mut out := RawImage{
		width: out_width
		height: out_height
		channels: channels
		data: []u8{len: out_width * out_height * channels}
	}
	
	for y := 0; y < out_height; y++ {
		for x := 0; x < out_width; x++ {
			out_idx := (y * out_width + x) * channels
			
			if x < target.width {
				target_idx := (y * target.width + x) * channels
				for c := 0; c < channels; c++ {
					if out_idx + c < out.data.len && target_idx + c < target.data.len {
						out.data[out_idx + c] = target.data[target_idx + c]
					}
				}
			} else if x >= target.width && x < target.width + divider_width {
				for c := 0; c < channels; c++ {
					if out_idx + c < out.data.len {
						out.data[out_idx + c] = 40
					}
				}
			} else {
				recon_x := x - target.width - divider_width
				recon_idx := (y * target.width + recon_x) * channels
				for c := 0; c < channels; c++ {
					if out_idx + c < out.data.len && recon_idx + c < reconstruction.data.len {
						out.data[out_idx + c] = reconstruction.data[recon_idx + c]
					}
				}
			}
		}
	}
	return out
}

fn compile_gif(_frame_count int, delay int, output_path string) bool {
	cmd := 'magick -delay ${delay} -loop 0 temp_frame_*.png "${output_path}"'
	res := os.execute(cmd)
	if res.exit_code == 0 {
		return true
	}
	
	cmd_fallback := 'convert -delay ${delay} -loop 0 temp_frame_*.png "${output_path}"'
	res_fallback := os.execute(cmd_fallback)
	if res_fallback.exit_code == 0 {
		return true
	}
	
	return false
}

fn clean_temp_frames(frame_count int) {
	for i := 0; i < frame_count; i++ {
		filename := 'temp_frame_${i:03d}.png'
		os.rm(filename) or {}
	}
}

fn render_text_with_font(text string, font_path string, bg_color_hex string, text_color_hex string, width int, height int, rtl bool) ?RawImage {
	temp_png := 'temp_render.png'
	rtl_opt := if rtl { '-direction right-to-left' } else { '' }
	gravity := if rtl { 'East' } else { 'West' }
	cmd := 'magick -size ${width}x${height} xc:#${bg_color_hex} -font "${font_path}" ${rtl_opt} -fill "#${text_color_hex}" -pointsize 14 -gravity ${gravity} -annotate +8+0 "${text}" ${temp_png}'
	mut res := os.execute(cmd)
	if res.exit_code != 0 {
		cmd_fallback := 'convert -size ${width}x${height} xc:#${bg_color_hex} -font "${font_path}" ${rtl_opt} -fill "#${text_color_hex}" -pointsize 14 -gravity ${gravity} -annotate +8+0 "${text}" ${temp_png}'
		res = os.execute(cmd_fallback)
	}
	
	if res.exit_code != 0 {
		return none
	}
	
	img := stbi.load(temp_png) or { return none }
	os.rm(temp_png) or {}
	return RawImage{
		width: img.width
		height: img.height
		channels: img.nr_channels
		data: unsafe { img.data.vbytes(img.width * img.height * img.nr_channels) }
	}
}

fn hex_to_rgb(hex string) RGB {
	if hex.len != 6 {
		return RGB{255, 255, 255}
	}
	r := u8(parse_hex_pair(hex[0..2]))
	g := u8(parse_hex_pair(hex[2..4]))
	b := u8(parse_hex_pair(hex[4..6]))
	return RGB{r, g, b}
}

fn parse_hex_pair(pair string) int {
	mut val := 0
	for c in pair.bytes() {
		val *= 16
		if c >= `0` && c <= `9` {
			val += int(c - `0`)
		} else if c >= `a` && c <= `f` {
			val += int(c - `a` + 10)
		} else if c >= `A` && c <= `F` {
			val += int(c - `A` + 10)
		}
	}
	return val
}

fn custom_pixelator(img RawImage, block_size int) RawImage {
	mut output := RawImage{
		width: img.width
		height: img.height
		channels: img.channels
		data: []u8{len: img.data.len}
	}

	for y := 0; y < img.height; y += block_size {
		for x := 0; x < img.width; x += block_size {
			mut r_sum := u64(0)
			mut g_sum := u64(0)
			mut b_sum := u64(0)
			mut count := 0

			for by := 0; by < block_size && (y + by) < img.height; by++ {
				for bx := 0; bx < block_size && (x + bx) < img.width; bx++ {
					px := (y + by) * img.width + (x + bx)
					idx := px * img.channels
					if idx + 2 < img.data.len {
						r_sum += img.data[idx]
						g_sum += img.data[idx + 1]
						b_sum += img.data[idx + 2]
						count++
					}
				}
			}

			if count > 0 {
				r_avg := u8(r_sum / u64(count))
				g_avg := u8(g_sum / u64(count))
				b_avg := u8(b_sum / u64(count))

				for by := 0; by < block_size && (y + by) < img.height; by++ {
					for bx := 0; bx < block_size && (x + bx) < img.width; bx++ {
						px := (y + by) * img.width + (x + bx)
						idx := px * img.channels
						if idx + 2 < img.data.len {
							output.data[idx] = r_avg
							output.data[idx + 1] = g_avg
							output.data[idx + 2] = b_avg
							if img.channels == 4 {
								output.data[idx + 3] = img.data[idx + 3]
							}
						}
					}
				}
			}
		}
	}
	return output
}

fn custom_blur(img RawImage, radius int) RawImage {
	mut output := RawImage{
		width: img.width
		height: img.height
		channels: img.channels
		data: []u8{len: img.data.len}
	}

	for y := 0; y < img.height; y++ {
		for x := 0; x < img.width; x++ {
			mut r_sum := u32(0)
			mut g_sum := u32(0)
			mut b_sum := u32(0)
			mut count := u32(0)

			for ky := -radius; ky <= radius; ky++ {
				for kx := -radius; kx <= radius; kx++ {
					ny := y + ky
					nx := x + kx
					if ny >= 0 && ny < img.height && nx >= 0 && nx < img.width {
						idx := (ny * img.width + nx) * img.channels
						r_sum += img.data[idx]
						g_sum += img.data[idx + 1]
						b_sum += img.data[idx + 2]
						count++
					}
				}
			}

			out_idx := (y * img.width + x) * img.channels
			if count > 0 {
				output.data[out_idx] = u8(r_sum / count)
				output.data[out_idx + 1] = u8(g_sum / count)
				output.data[out_idx + 2] = u8(b_sum / count)
				if img.channels == 4 {
					output.data[out_idx + 3] = img.data[out_idx + 3]
				}
			}
		}
	}
	return output
}

fn calculate_sliding_mae_masked(target RawImage, template RawImage, mask RawImage) (f64, int, int) {
	if target.width < template.width || target.height < template.height {
		return math.max_f64, 0, 0
	}

	mut lowest_mae := math.max_f64
	mut best_x := 0
	mut best_y := 0
	has_mask := mask.data.len == target.data.len && mask.width == target.width && mask.height == target.height

	for ty := 0; ty <= target.height - template.height; ty++ {
		for tx := 0; tx <= target.width - template.width; tx++ {
			mut sum := 0.0
			mut weight_sum := 0.0

			for y := 0; y < template.height; y++ {
				for x := 0; x < template.width; x++ {
					idx_temp := (y * template.width + x) * template.channels
					idx_target := ((ty + y) * target.width + (tx + x)) * target.channels

					mut weight := 1.0
					if has_mask {
						mask_val := mask.data[idx_target]
						alpha := f64(mask_val) / 255.0
						weight = 1.0 - alpha
					}

					if weight <= 0.0 {
						continue
					}

					diff_r := math.abs(f64(target.data[idx_target]) - f64(template.data[idx_temp]))
					diff_g := math.abs(f64(target.data[idx_target + 1]) - f64(template.data[idx_temp + 1]))
					diff_b := math.abs(f64(target.data[idx_target + 2]) - f64(template.data[idx_temp + 2]))

					sum += weight * (diff_r + diff_g + diff_b)
					weight_sum += weight * 3.0
				}
			}

			if weight_sum > 0.0 {
				mae := sum / weight_sum
				if mae < lowest_mae {
					lowest_mae = mae
					best_x = tx
					best_y = ty
				}
			}
		}
	}
	return lowest_mae, best_x, best_y
}

fn get_char_bitmap(c rune) []u8 {
	return match c {
		`a` { [u8(0x0c), 0x12, 0x1e, 0x12, 0x12] }
		`b` { [u8(0x1c), 0x12, 0x1c, 0x12, 0x1c] }
		`c` { [u8(0x0e), 0x10, 0x10, 0x10, 0x0e] }
		`d` { [u8(0x1c), 0x12, 0x12, 0x12, 0x1c] }
		`e` { [u8(0x1e), 0x10, 0x1c, 0x10, 0x1e] }
		`f` { [u8(0x1e), 0x10, 0x1c, 0x10, 0x10] }
		`g` { [u8(0x0e), 0x10, 0x16, 0x12, 0x0e] }
		`h` { [u8(0x12), 0x12, 0x1e, 0x12, 0x12] }
		`i` { [u8(0x0e), 0x04, 0x04, 0x04, 0x0e] }
		`j` { [u8(0x0e), 0x02, 0x02, 0x12, 0x0c] }
		`k` { [u8(0x12), 0x14, 0x18, 0x14, 0x12] }
		`l` { [u8(0x10), 0x10, 0x10, 0x10, 0x1e] }
		`m` { [u8(0x11), 0x1b, 0x15, 0x11, 0x11] }
		`n` { [u8(0x12), 0x16, 0x1a, 0x12, 0x12] }
		`o` { [u8(0x0c), 0x12, 0x12, 0x12, 0x0c] }
		`p` { [u8(0x1c), 0x12, 0x1c, 0x10, 0x10] }
		`q` { [u8(0x0c), 0x12, 0x12, 0x14, 0x0a] }
		`r` { [u8(0x1c), 0x12, 0x1c, 0x14, 0x12] }
		`s` { [u8(0x0e), 0x10, 0x0c, 0x02, 0x1c] }
		`t` { [u8(0x1f), 0x04, 0x04, 0x04, 0x04] }
		`u` { [u8(0x12), 0x12, 0x12, 0x12, 0x0c] }
		`v` { [u8(0x12), 0x12, 0x12, 0x0a, 0x04] }
		`w` { [u8(0x11), 0x11, 0x15, 0x15, 0x0a] }
		`x` { [u8(0x12), 0x12, 0x0c, 0x12, 0x12] }
		`y` { [u8(0x12), 0x12, 0x0c, 0x04, 0x04] }
		`z` { [u8(0x1f), 0x02, 0x04, 0x08, 0x1f] }
		`0` { [u8(0x0e), 0x12, 0x12, 0x12, 0x0e] }
		`1` { [u8(0x04), 0x0c, 0x04, 0x04, 0x0e] }
		`2` { [u8(0x0e), 0x02, 0x06, 0x08, 0x0f] }
		`3` { [u8(0x0e), 0x02, 0x06, 0x02, 0x0e] }
		`4` { [u8(0x12), 0x12, 0x1e, 0x02, 0x02] }
		`5` { [u8(0x1f), 0x10, 0x1e, 0x02, 0x1c] }
		`6` { [u8(0x0c), 0x10, 0x1c, 0x12, 0x0c] }
		`7` { [u8(0x1f), 0x02, 0x04, 0x08, 0x08] }
		`8` { [u8(0x0c), 0x12, 0x0c, 0x12, 0x0c] }
		`9` { [u8(0x0c), 0x12, 0x0e, 0x02, 0x0c] }
		else { [u8(0x00), 0x00, 0x00, 0x00, 0x00] }
	}
}

fn mock_render_text(text string, width int, height int, channels int, bg_color RGB, text_color RGB, bg_img RawImage, margin_x int, margin_y int) RawImage {
	mut data := []u8{len: width * height * channels}

	if bg_img.data.len == data.len {
		for i in 0 .. data.len {
			data[i] = bg_img.data[i]
		}
	} else {
		for i := 0; i < data.len; i += channels {
			data[i] = bg_color.r
			data[i + 1] = bg_color.g
			data[i + 2] = bg_color.b
			if channels == 4 {
				data[i + 3] = 255
			}
		}
	}

	char_width := 5
	char_height := 5
	gap := 2

	runes := text.runes()
	for i in 0 .. runes.len {
		c := runes[i]
		bitmap := get_char_bitmap(c)
		x_start := i * (char_width + gap) + margin_x
		for y in 0 .. char_height {
			img_y := margin_y + y
			if img_y >= height {
				continue
			}
			row_byte := bitmap[y]
			for x in 0 .. char_width {
				img_x := x_start + x
				if img_x >= width {
					continue
				}
				bit := (row_byte >> (4 - x)) & 1
				if bit == 1 {
					idx := (img_y * width + img_x) * channels
					if idx + 2 < data.len {
						data[idx] = text_color.r
						data[idx + 1] = text_color.g
						data[idx + 2] = text_color.b
					}
				}
			}
		}
	}
	return RawImage{
		width: width
		height: height
		channels: channels
		data: data
	}
}

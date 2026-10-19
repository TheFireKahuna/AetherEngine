//! Amplifier RPUs for the p7fel_card bit-survival test card.
//!
//!   card_rpu <src_rpu.bin> <out_dir> <N> <slope> <lo> <hi> <l1_min> <l1_max> <l1_avg>
//!
//! Takes the first RPU of a dovi_tool RPU file (the card clip's own Profile 7 FEL RPU), converts it the
//! way the engine does for composed frames (`DoviRpuConverter.dualLayerUnspec62`: libdovi mode 2, then
//! remove_mapping), and writes three single-RPU files into <out_dir>:
//!
//!   card_identity.bin  the converted RPU as is: identity luma and chroma mapping (the control)
//!   card_amp10.bin     the same RPU with the steep-window luma curve below, L1 replaced by <l1_*> (clamped
//!                      as dovi_tool generate clamps it: min_pq <= 12)
//!   card_amp12.bin     the same curve declared at bl_bit_depth 12, if libdovi will write it (it will not:
//!                      the reason is printed and no file is written)
//!
//! Byte format of every file: one HEVC UNSPEC62 NAL unit exactly as libdovi's `write_hevc_unspec62_nalu`
//! (C API `dovi_write_unspec62_nalu`) returns it: the 2-byte NAL header 0x7C 0x01, then the RPU payload
//! (0x19 prefix ... CRC32, 0x80) with start-code emulation prevention bytes inserted. No Annex B start
//! code, no length prefix. dovi_tool's own RPU files hold the payload without the 0x7C 0x01 header, so to
//! read one with `dovi_tool info -i` replace those two bytes with a 00 00 00 01 start code.
//!
//! Luma curve, in 10-bit input codes x (all three pieces first order, output in 10-bit code units):
//!   x <  lo        f(x) = x                                     identity
//!   lo <= x < hi   f(x) = lo + slope * (x - lo)                 the amplifier window
//!   x >= hi        f(x) = f(hi) + (x - hi) * (1023 - f(hi)) / (1023 - hi)   back to f(1023) = 1023
//! Continuous at both pivots, monotonic, and inside [0, 1023] everywhere, so nothing clips. The RPU
//! carries it normalised (input / 2^bl_bit_depth, output / 2^bl_bit_depth before the VDR scaling), with
//! pivots delta-coded: [0, lo, hi - lo, 1023 - hi]. Chroma curves stay identity, NLQ stays absent (8.1).
use std::{env, fs, path::Path};

use anyhow::{Context, Result, bail, ensure};
use dolby_vision::rpu::{
    ConversionMode,
    dovi_rpu::DoviRpu,
    extension_metadata::blocks::{ExtMetadataBlock, ExtMetadataBlockLevel1},
    rpu_data_mapping::{DoviMappingMethod, DoviPolynomialCurve},
    utils::parse_rpu_file,
    vdr_dm_data::CmVersion,
};

const DENOM: u32 = 23;

/// One fixed-point coefficient as the RPU carries it: signed integer part (se(v)) plus an unsigned
/// 23-bit fraction, value = int + frac / 2^23 (coefficient_data_type 0, coefficient_log2_denom 23).
fn fixed(v: f64) -> (i64, u64) {
    let scaled = (v * f64::from(1u32 << DENOM)).round() as i64;
    let int = scaled.div_euclid(1 << DENOM);
    let frac = scaled.rem_euclid(1 << DENOM) as u64;
    (int, frac)
}

fn unfixed(int: i64, frac: u64) -> f64 {
    int as f64 + frac as f64 / f64::from(1u32 << DENOM)
}

/// (c0, c1) per piece in normalised units, for input codes at `depth` bits.
fn pieces(lo: f64, hi: f64, slope: f64) -> Vec<(f64, f64)> {
    let f_hi = lo + slope * (hi - lo);
    let s2 = (1023.0 - f_hi) / (1023.0 - hi);
    // f(x) = a + b*x in 10-bit codes -> normalised: f/1024 = a/1024 + b*(x/1024).
    vec![(0.0, 1.0), (lo * (1.0 - slope) / 1024.0, slope), ((f_hi - hi * s2) / 1024.0, s2)]
}

fn set_curve(rpu: &mut DoviRpu, depth: u32, lo: u16, hi: u16, slope: f64) -> Result<()> {
    let scale = 1u16 << (depth - 10);
    let max = (1u32 << depth) - 1;
    let mapping = rpu.rpu_data_mapping.as_mut().context("RPU has no mapping")?;
    let luma = &mut mapping.curves[0];
    luma.num_pivots_minus2 = 2;
    luma.pivots = vec![0, lo * scale, (hi - lo) * scale, (max - u32::from(hi * scale)) as u16];
    luma.mapping_idc = DoviMappingMethod::Polynomial;
    luma.mmr = None;
    let mut poly = DoviPolynomialCurve::p81_default();
    poly.poly_order_minus1 = vec![0; 3];
    poly.linear_interp_flag = vec![false; 3];
    poly.poly_coef_int.clear();
    poly.poly_coef.clear();
    for (c0, c1) in pieces(f64::from(lo), f64::from(hi), slope) {
        let (i0, f0) = fixed(c0);
        let (i1, f1) = fixed(c1);
        poly.poly_coef_int.push([i0, i1].into_iter().collect());
        poly.poly_coef.push([f0, f1].into_iter().collect());
    }
    luma.polynomial = Some(poly);
    rpu.header.bl_bit_depth_minus8 = u64::from(depth - 8);
    rpu.modified = true;
    Ok(())
}

/// Evaluates the luma curve of a parsed RPU at a (possibly fractional) 10-bit input code, the way the
/// engine's composer does (normalise by 2^depth, pick the piece by the accumulated pivots, clamp
/// to the outer pivots), and returns the output in 10-bit code units.
fn eval(rpu: &DoviRpu, x10: f64) -> f64 {
    let depth = rpu.header.bl_bit_depth_minus8 as u32 + 8;
    let unit = f64::from(1u32 << depth);
    let x = x10 * unit / 1024.0;
    let curve = &rpu.rpu_data_mapping.as_ref().unwrap().curves[0];
    let mut acc = 0f64;
    let piv: Vec<f64> = curve.pivots.iter().map(|&p| { acc += f64::from(p); acc }).collect();
    let mut piece = 0;
    for (i, p) in piv.iter().take(piv.len() - 1).enumerate() {
        if x >= *p { piece = i; }
    }
    let poly = curve.polynomial.as_ref().unwrap();
    let xc = x.clamp(piv[0], piv[piv.len() - 1]) / unit;
    let c = |j: usize| unfixed(poly.poly_coef_int[piece][j], poly.poly_coef[piece][j]);
    let mut y = c(0);
    for j in 1..=poly.poly_order_minus1[piece] as usize + 1 { y += c(j) * xc.powi(j as i32); }
    y * 1024.0
}

fn describe(name: &str, bytes: &[u8]) -> Result<DoviRpu> {
    let rpu = DoviRpu::parse_unspec62_nalu(bytes).with_context(|| format!("{name}: libdovi does not parse it back"))?;
    let again = rpu.write_hevc_unspec62_nalu()?;
    ensure!(again == bytes, "{name}: parse/write round trip changed the bytes");
    let m = rpu.rpu_data_mapping.as_ref().unwrap();
    let c = &m.curves[0];
    let p = c.polynomial.as_ref().unwrap();
    println!("{name}: {} bytes, profile {}, bl_bit_depth {}, disable_residual {}, nlq {}, round trip ok",
        bytes.len(), rpu.dovi_profile, rpu.header.bl_bit_depth_minus8 + 8, rpu.header.disable_residual_flag,
        if m.nlq.is_some() { "present" } else { "absent" });
    println!("  luma pivots (delta-coded) {:?}", c.pivots);
    for i in 0..p.poly_coef.len() {
        println!("  piece {i}: c0 = {:.10}, c1 = {:.10}", unfixed(p.poly_coef_int[i][0], p.poly_coef[i][0]),
            unfixed(p.poly_coef_int[i][1], p.poly_coef[i][1]));
    }
    let probes = [0.0, 446.0, 447.0, 448.0, 448.25, 448.5, 448.75, 449.0, 450.0, 451.0, 600.0, 940.0, 1023.0];
    let row: Vec<String> = probes.iter().map(|&x| format!("{x}->{:.2}", eval(&rpu, x))).collect();
    println!("  f(x), 10-bit codes: {}", row.join("  "));
    if let Some(dm) = rpu.vdr_dm_data.as_ref()
        && let Some(ExtMetadataBlock::Level1(l1)) = dm.get_block(1)
    {
        println!("  L1 min/max/avg {} / {} / {}", l1.min_pq, l1.max_pq, l1.avg_pq);
    }
    Ok(rpu)
}

fn main() -> Result<()> {
    let a: Vec<String> = env::args().collect();
    if a.len() != 10 {
        bail!("usage: card_rpu <src_rpu.bin> <out_dir> <N> <slope> <lo> <hi> <l1_min> <l1_max> <l1_avg>");
    }
    let out = Path::new(&a[2]);
    let n: u16 = a[3].parse()?;
    let slope: f64 = a[4].parse()?;
    let (lo, hi): (u16, u16) = (a[5].parse()?, a[6].parse()?);
    let l1: Vec<u16> = a[7..10].iter().map(|s| s.parse()).collect::<Result<_, _>>()?;
    ensure!(lo < n && n + 1 < hi && hi < 1023, "the window [lo, hi) must contain N .. N+1 with room on both sides");

    let mut base = parse_rpu_file(&a[1])?.into_iter().next().context("no RPU in the source file")?;
    base.convert_with_mode(ConversionMode::To81)?;
    base.remove_mapping();

    let identity = base.write_hevc_unspec62_nalu()?;
    fs::write(out.join("card_identity.bin"), &identity)?;
    describe("card_identity.bin", &identity)?;

    let mut amp = base.clone();
    set_curve(&mut amp, 10, lo, hi, slope)?;
    if let Some(dm) = amp.vdr_dm_data.as_mut() {
        dm.replace_metadata_block(ExtMetadataBlock::Level1(ExtMetadataBlockLevel1::from_stats_cm_version(l1[0], l1[1], l1[2], CmVersion::V29)))?;
    }
    let bytes = amp.write_hevc_unspec62_nalu()?;
    fs::write(out.join("card_amp10.bin"), &bytes)?;
    let parsed = describe("card_amp10.bin", &bytes)?;
    for (x, want) in [(f64::from(n), f64::from(lo) + slope * f64::from(n - lo)), (f64::from(lo) - 1.0, f64::from(lo) - 1.0)] {
        ensure!((eval(&parsed, x) - want).abs() < 1e-3, "curve check failed at {x}");
    }

    let mut amp12 = amp.clone();
    set_curve(&mut amp12, 12, lo, hi, slope)?;
    let _ = fs::remove_file(out.join("card_amp12.bin"));
    match amp12.write_hevc_unspec62_nalu() {
        Ok(b) => {
            fs::write(out.join("card_amp12.bin"), &b)?;
            describe("card_amp12.bin", &b)?;
        }
        Err(e) => println!("card_amp12.bin: not written, libdovi refuses bl_bit_depth 12: {e}"),
    }
    Ok(())
}

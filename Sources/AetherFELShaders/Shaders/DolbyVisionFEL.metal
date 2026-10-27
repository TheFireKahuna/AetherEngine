// The Dolby Vision FEL composer's kernels (DoviFelComposer): the base and enhancement layers composed into one
// picture, as the composer's fixed-point process defines it.

#include <metal_stdlib>
using namespace metal;

// Metal's default float semantics, stated here so no build setting changes them.
#pragma METAL fp math_mode(fast)

typedef uint dovi_u32;
typedef int  dovi_i32;
/* DOVI_SHARED_STRUCTS_BEGIN */
/* ---- Target output modes (unread: no kernel switches on them; the output's range is the RPU's own,
   carried by the output buffer's format) ---- */
#define DOVI_TARGET_MODE_PROFILE_8_1  0 /* Rec.2020 YCbCr PQ 10-bit limited range */
#define DOVI_TARGET_MODE_PROFILE_5    1 /* Dolby IPTPQc2 10-bit full range */

/* ---- Dither modes ---- */
#define DOVI_DITHER_NONE              0 /* round to nearest */
#define DOVI_DITHER_BAYER_8X8         1 /* ordered dither, inverted on odd frames */
#define DOVI_DITHER_FULL_PRECISION    3 /* keep the VDR bits below the 10-bit code in P010's low 6 bits */
#define DOVI_DEBUG_RAW_VDR            2 /* test only: write the un-quantised VDR code << 4 (12-bit in 16) */
#define DOVI_DITHER_BLUE_NOISE        4 /* static 64x64 blue-noise threshold map, no per-frame change */

/* ---- nlq_method_idc. Anything other than LINEAR yields no
   residual rather than a wrong inverse, degrading to base-layer output. ---- */
#define DOVI_NLQ_METHOD_LINEAR        0
#define DOVI_NLQ_METHOD_NONE          0xFFFFFFFFu

/* ---- mapping_idc, per reshaping piece ---- */
#define DOVI_MAPPING_POLYNOMIAL       0
#define DOVI_MAPPING_MMR              1

/* ---- per-frame MMR table (buffer 3): [Y, Cb, Cr][piece 0..8][24 coefficients] as int. Coefficient (power - 1) * 8
        + subset is the one against the product of `subset`'s inputs (bit 0 s0, bit 1 s1, bit 2 s2) raised to power
        1, 2 or 3; the empty subset's product is 1.0, so slot 0 is the constant and slots 8 and 16 are zero. Piece 8 of
        each component is all zeros, and a piece's coefficients above its order are zero: every sample sums all 24
        against some piece. ---- */
#define DOVI_MMR_TABLE_PIECE_STRIDE      24
#define DOVI_MMR_TABLE_PIECES            9
#define DOVI_MMR_ZERO_PIECE              8
#define DOVI_MMR_TABLE_COMPONENT_STRIDE  (DOVI_MMR_TABLE_PIECES * DOVI_MMR_TABLE_PIECE_STRIDE)

/* ---- flags ---- */
#define DOVI_FLAG_DISABLE_RESIDUAL    0x1u /* disable_residual_flag, or el_type == MEL */
#define DOVI_FLAG_CHROMA_422          0x4u /* sv22: dovi_compose_chroma writes its 16-bit sums for dovi_chroma_420_to_422 */

/* Piecewise reshaping curve for one component.
 *
 * num_pivots < 2 means "identity passthrough"; the parser installs that as the
 * fail-safe whenever a curve cannot be trusted, so a malformed RPU degrades to
 * the base layer instead of to black.
 *
 * pivots are absolute (prefix-summed) BL code values, ascending, and pivots[0]
 * / pivots[num_pivots - 1] bound the evaluation domain. method[i] selects how
 * piece i is evaluated. The syntax lets a component mix polynomial and MMR
 * pieces, but libdovi keeps one mapping_idc per component (the last piece's) and
 * one coefficient list per method, so a mixed curve cannot be read back
 * through its C API, and DoviRpuGuard refuses it before it gets here: in
 * practice every piece of a component has the same method. order[i] is
 * the polynomial order for a polynomial piece and the MMR order for an MMR
 * piece. coef[i][j] is Q(coef_shift[i]) and is evaluated against inputs
 * normalised by dividing the BL code value by 2^bl_bit_depth (bl_max + 1), the
 * fixed-point convention of Dolby's reference. */
struct DoviPolynomialParams {
    dovi_u32 num_pivots;
    dovi_u32 pivots[9];
    dovi_u32 method[8];
    dovi_u32 order[8];
    dovi_i32 coef[8][3];
    dovi_u32 coef_shift[8];
};

/* Multiple-model regression coefficients, one set per reshaping piece.
 *
 * The piece count, the per-piece MMR order and the piece selection all live in
 * the matching DoviPolynomialParams; this block only carries the coefficients,
 * laid out as coef[piece][order * 7 + term] over the seven cross terms
 * [y, u, v, yu, yv, uv, yuv]. Order o contributes those terms raised to the
 * power o + 1. Every coefficient is Q(coef_shift) against normalised inputs. */
struct DoviMmrParams {
    dovi_i32 mmr_constant[8];
    dovi_i32 coef[8][21];
    dovi_u32 coef_shift;
};

/* Inverse non-linear quantisation for one component.
 *
 * nlq_scale and nlq_threshold are Q(coefficient_log2_denom) in the normalised
 * residual domain; nlq_shift = coefficient_log2_denom - vdr_bit_depth converts
 * that product into VDR code units. vdr_in_max is the ceiling already reduced
 * to VDR code units by the parser. */
struct DoviNlqParams {
    dovi_u32 nlq_method;
    dovi_i32 nlq_offset;
    dovi_i32 nlq_scale;
    dovi_i32 nlq_threshold;
    dovi_i32 vdr_in_max;
    dovi_u32 nlq_shift;
    dovi_u32 nlq_pivots[2];
};

struct DoviMetalParams {
    dovi_u32 bl_width;
    dovi_u32 bl_height;
    dovi_u32 el_width;
    dovi_u32 el_height;

    dovi_u32 target_mode;
    dovi_u32 dither_mode;
    dovi_u32 frame_index;
    dovi_u32 flags;

    struct DoviPolynomialParams poly_y;
    struct DoviMmrParams        mmr_y;
    struct DoviNlqParams        nlq_y;

    struct DoviPolynomialParams poly_cb;
    struct DoviMmrParams        mmr_cb;
    struct DoviNlqParams        nlq_cb;

    struct DoviPolynomialParams poly_cr;
    struct DoviMmrParams        mmr_cr;
    struct DoviNlqParams        nlq_cr;

    dovi_u32 min_pq;
    dovi_u32 max_pq;
    dovi_u32 avg_pq;

    /* Bit-depth derived constants, so the kernels carry no literal 1023/4095.
       bl_max   = (1 << bl_bit_depth) - 1
       vdr_max  = (1 << vdr_bit_depth) - 1
       vdr_scale = 1 << (vdr_bit_depth - bl_bit_depth)
       Curve inputs are normalised by 2^bl_bit_depth (bl_max + 1) and a normalised
       prediction is denormalised by (bl_max + 1) * vdr_scale = 2^vdr_bit_depth, the
       same scale both ways, so an identity curve is bit-exact and a neutral chroma
       (code 512) maps to exactly 2048 (DoViBaker agrees; scaling by bl_max instead
       puts it at 2049, and up to 2041 through an MMR constant). */
    dovi_u32 bl_max;
    dovi_u32 vdr_max;
    dovi_u32 vdr_scale;

    /* The base layer's chroma siting as FFmpeg's AVChromaLocation (chroma_sample_loc_type + 1; 0 =
       unspecified). Read only by dovi_chroma_420_to_422, for the vertical phase of each 4:2:2 row. */
    dovi_u32 bl_chroma_loc;

    /* FEL / MEL split view: the luma column from which the residual is no longer added, so the left of the
       picture is the full FEL result and the right what a MEL stream decodes to. 0 = no split. */
    dovi_u32 residual_split_x;
};
/* DOVI_SHARED_STRUCTS_END */
// The 64x64 blue-noise threshold map: each rank 0...4095 once, 64 rows of 64.
constant ushort dovi_blue_noise_64[4096] = {
    878, 3318, 259, 4002, 1917, 17, 1229, 3902, 2506, 3722, 2765, 3421, 4054, 2678, 1796, 126, 2495, 747, 2858, 1938, 1265, 2957, 1698, 3620, 2775, 1907, 3245, 1205, 4001, 1524, 3393, 2383,
    3806, 3054, 690, 1499, 1130, 3000, 1333, 3497, 3166, 247, 3310, 1877, 3708, 2920, 1716, 3159, 2224, 3294, 2018, 4073, 288, 1912, 818, 3126, 2020, 3265, 1279, 2483, 660, 2200, 377, 1984,
    3692, 1451, 2933, 1135, 2643, 3576, 2899, 1795, 219, 1393, 713, 2210, 403, 1018, 3731, 1290, 2986, 1636, 433, 2597, 4087, 571, 3296, 1376, 783, 127, 2367, 384, 2688, 996, 164, 2033,
    850, 2626, 1828, 2323, 3633, 814, 1847, 413, 2179, 1705, 4008, 2309, 2, 867, 3506, 517, 3886, 109, 2467, 655, 3002, 3461, 1605, 2525, 234, 2725, 453, 3942, 3417, 1579, 2876, 1260,
    87, 2094, 3538, 748, 1649, 463, 2300, 816, 3369, 2978, 1942, 3213, 1511, 2391, 3352, 661, 2064, 3260, 3582, 1485, 874, 2459, 208, 2146, 3952, 1672, 2953, 3661, 1858, 3517, 2891, 533,
    1346, 3560, 236, 3297, 509, 2585, 3982, 2810, 934, 2954, 644, 1141, 1551, 2582, 1992, 1285, 2753, 1545, 1015, 3671, 1324, 2352, 480, 4000, 1113, 3569, 1515, 2059, 148, 1020, 3816, 3134,
    1673, 2729, 346, 2410, 3834, 3157, 1423, 4034, 2093, 1153, 343, 3874, 836, 2919, 1904, 285, 3969, 1158, 96, 2173, 3193, 1755, 3750, 2716, 1220, 3434, 893, 1392, 650, 2263, 1564, 3974,
    3108, 2189, 1111, 2789, 1652, 2079, 111, 1541, 3754, 1361, 2488, 3595, 3149, 3940, 307, 3015, 731, 3551, 2647, 1798, 157, 2885, 923, 3034, 1815, 2302, 866, 3062, 2758, 1840, 688, 2314,
    3910, 973, 3409, 1299, 2054, 1017, 106, 2618, 562, 3676, 2674, 1773, 27, 3562, 1405, 2777, 2411, 815, 2721, 3823, 382, 1110, 3010, 695, 309, 2581, 2221, 3869, 16, 3276, 1075, 2534,
    327, 1616, 3882, 872, 3709, 1227, 3381, 2277, 494, 3440, 152, 1839, 535, 2164, 1073, 3789, 1848, 2194, 456, 3058, 3905, 2048, 1509, 3657, 67, 3317, 584, 3791, 1330, 3533, 2639, 444,
    1425, 1937, 3021, 604, 2843, 3747, 1864, 3322, 1631, 2394, 899, 3070, 2187, 1116, 479, 3758, 1566, 3137, 1845, 1350, 2427, 3505, 2014, 1508, 3284, 1832, 510, 3046, 2007, 2713, 3749, 728,
    1936, 3412, 150, 2269, 3078, 408, 2936, 1072, 2675, 2005, 3081, 911, 2822, 1467, 3344, 2479, 61, 1332, 3384, 797, 1183, 2541, 613, 2178, 1262, 2612, 1736, 2417, 402, 2154, 1191, 3208,
    2436, 134, 4088, 1692, 261, 2363, 805, 2972, 1284, 171, 3454, 1427, 4017, 2465, 3325, 711, 2257, 235, 3460, 556, 2893, 912, 57, 2331, 4045, 1119, 3570, 1615, 858, 1313, 423, 2351,
    2982, 1218, 2708, 625, 1448, 1860, 3917, 763, 1696, 4062, 1248, 2392, 3746, 231, 827, 1656, 2925, 3701, 2334, 1670, 3252, 204, 3808, 3374, 2850, 432, 4063, 1000, 3336, 26, 3762, 733,
    3634, 2129, 909, 2547, 3244, 1489, 3534, 471, 3948, 1905, 2752, 636, 282, 1702, 2866, 1950, 1228, 4041, 1031, 2123, 3916, 1733, 3672, 3120, 786, 2709, 177, 2462, 3985, 3218, 1790, 3552,
    895, 4064, 1743, 3251, 3609, 2625, 73, 2377, 3243, 289, 628, 3456, 1771, 2231, 4027, 3181, 618, 1077, 262, 4006, 1981, 2719, 1086, 1827, 843, 1596, 3096, 2002, 1442, 2932, 1814, 2710,
    513, 3343, 1345, 3589, 687, 2037, 1131, 2686, 2240, 975, 3753, 2117, 3121, 841, 3711, 85, 3236, 2587, 2945, 1543, 255, 2739, 1316, 454, 2144, 1459, 2977, 671, 2069, 264, 2778, 1498,
    65, 2087, 469, 2389, 849, 1187, 2022, 3714, 1344, 2796, 1618, 2979, 1105, 519, 2690, 1271, 2061, 2504, 2865, 1422, 692, 3124, 476, 2406, 3713, 161, 3513, 681, 2517, 3947, 948, 1598,
    1146, 2860, 1875, 342, 2770, 3898, 32, 1661, 3239, 245, 1518, 3359, 1151, 2627, 1388, 2371, 1643, 415, 787, 3301, 2381, 714, 3444, 2537, 1802, 3832, 3339, 1293, 3527, 1016, 2252, 3071,
    3742, 2613, 1398, 3818, 272, 2859, 3475, 529, 890, 2201, 3807, 35, 2526, 3561, 1885, 135, 3274, 3772, 401, 3398, 2265, 1606, 3928, 1294, 3025, 2147, 2634, 1222, 461, 2230, 251, 3179,
    2369, 155, 3829, 2271, 1281, 3115, 2402, 3675, 700, 2888, 2360, 445, 1834, 3958, 569, 3405, 988, 3844, 2042, 1276, 3721, 1876, 1096, 3065, 93, 974, 491, 2372, 1699, 3893, 482, 1267,
    718, 3403, 1028, 2967, 2203, 1794, 1460, 3077, 2601, 1810, 3282, 760, 1501, 3083, 972, 3884, 1514, 1804, 837, 1230, 3606, 19, 2584, 1965, 331, 987, 1538, 3665, 3003, 3400, 1913, 3712,
    707, 1521, 3049, 789, 1756, 498, 983, 1925, 1322, 4058, 1069, 3548, 3014, 163, 2103, 2964, 1808, 2552, 3464, 8, 2999, 345, 3984, 1510, 3572, 2693, 1951, 2912, 151, 2653, 3230, 1949,
    2416, 294, 1586, 3303, 689, 4013, 1019, 188, 3864, 371, 1175, 2060, 3980, 2287, 387, 2799, 574, 2422, 2762, 2013, 2952, 1014, 3223, 757, 3431, 4022, 2788, 74, 1715, 862, 1295, 2683,
    2118, 3567, 1109, 2580, 4003, 3280, 2820, 3510, 405, 2570, 2040, 735, 1560, 2457, 1176, 3697, 217, 666, 1426, 2248, 1003, 2507, 1995, 678, 2253, 1240, 4093, 729, 3469, 1480, 861, 3673,
    1709, 3983, 2655, 1972, 13, 2508, 3357, 2285, 1591, 3446, 2456, 2904, 185, 1320, 3516, 1935, 1021, 3679, 226, 4089, 594, 1750, 3737, 1433, 2450, 1792, 619, 2193, 3792, 2466, 548, 4049,
    1762, 399, 3337, 86, 2035, 1385, 210, 2234, 1624, 3088, 66, 3830, 2767, 3483, 829, 1512, 2781, 4071, 3056, 1757, 3812, 2840, 410, 3320, 2973, 229, 1587, 3125, 1162, 2125, 2529, 88,
    2908, 933, 534, 3597, 1210, 3007, 1731, 516, 2846, 938, 565, 3615, 1719, 838, 2474, 3313, 2974, 1257, 3220, 1464, 2336, 2671, 170, 2180, 407, 3172, 1164, 3309, 1431, 2819, 196, 3136,
    917, 2906, 2254, 1687, 3707, 685, 2493, 3857, 873, 3458, 1437, 1104, 2207, 298, 3105, 1986, 2326, 944, 421, 3396, 762, 1389, 3592, 1684, 897, 2567, 3627, 2310, 352, 3936, 617, 3495,
    1200, 2275, 3210, 1483, 2169, 768, 3728, 1311, 2096, 4076, 1450, 1997, 3123, 3775, 503, 1529, 47, 2260, 1835, 337, 3503, 1150, 3113, 3951, 888, 2622, 3827, 318, 963, 1891, 3439, 1335,
    2637, 3918, 586, 1189, 2792, 3145, 1022, 1863, 460, 2782, 1952, 3281, 624, 1769, 3896, 394, 3549, 1231, 2676, 2085, 197, 2424, 1123, 2162, 3873, 553, 1915, 971, 2794, 1830, 3013, 1526,
    2011, 3757, 241, 2717, 3955, 379, 2619, 3413, 80, 3169, 2571, 333, 1082, 2750, 2106, 3991, 804, 2654, 3734, 961, 2869, 658, 1968, 1351, 2900, 1623, 1991, 2330, 3023, 3950, 686, 2071,
    271, 1466, 3453, 2397, 353, 1544, 3641, 2633, 1306, 3981, 266, 2374, 3732, 2685, 1377, 774, 3203, 1714, 3730, 1484, 3158, 4011, 2754, 137, 3107, 1458, 3408, 22, 3677, 1278, 3324, 369,
    2602, 715, 1688, 1048, 3161, 1914, 914, 2320, 1167, 1797, 800, 3463, 2364, 140, 1289, 3442, 1665, 3053, 452, 2091, 3863, 1642, 3389, 485, 3617, 112, 724, 3684, 1523, 21, 2452, 3647,
    1126, 1939, 3004, 846, 4072, 2073, 28, 3419, 2160, 788, 3005, 1565, 958, 142, 2985, 2455, 2062, 62, 649, 2337, 977, 1859, 601, 3531, 2012, 1089, 2924, 2523, 1638, 776, 2343, 1062,
    4057, 2983, 3478, 2432, 116, 1409, 2914, 3897, 314, 3653, 3009, 1347, 3939, 1844, 2890, 543, 2398, 1106, 3270, 1502, 2491, 191, 2651, 2131, 1101, 2477, 3333, 1253, 2756, 900, 1679, 3194,
    2312, 3715, 108, 1779, 3305, 1263, 2897, 581, 1663, 3685, 1157, 2586, 3568, 1923, 4023, 1118, 3383, 2744, 3937, 2975, 265, 3299, 1438, 875, 2435, 316, 4021, 2184, 501, 3842, 2773, 99,
    1766, 1308, 520, 2031, 3805, 3349, 611, 1659, 2723, 2051, 451, 2223, 662, 3215, 980, 3800, 1998, 160, 4019, 610, 1225, 3586, 825, 3079, 3903, 1871, 2969, 336, 2211, 3550, 2901, 466,
    755, 2784, 1039, 2631, 483, 2454, 896, 3187, 2328, 166, 3258, 465, 2239, 682, 1650, 311, 1503, 857, 1823, 1328, 3643, 2143, 2699, 3909, 3008, 1768, 806, 1356, 3094, 1895, 3372, 2122,
    3565, 2359, 887, 2830, 1580, 1103, 2249, 3518, 1264, 864, 2827, 3717, 1703, 2595, 257, 1519, 3416, 2665, 1772, 2849, 2278, 3180, 1758, 1391, 258, 769, 1572, 4069, 599, 1993, 1291, 3935,
    1522, 3406, 2126, 3848, 1571, 3525, 1964, 1435, 4020, 2745, 1778, 1357, 3391, 2733, 3104, 3786, 2313, 3520, 380, 2521, 1066, 504, 1710, 64, 1244, 3331, 2629, 3739, 221, 1177, 694, 1434,
    418, 3195, 3900, 297, 2519, 481, 3093, 69, 2511, 3930, 1540, 310, 1108, 3535, 2098, 2990, 702, 1318, 3630, 940, 4, 3945, 524, 2232, 2771, 3500, 2324, 1134, 2687, 3261, 141, 1889,
    3092, 227, 1301, 683, 3057, 136, 3776, 392, 1085, 708, 2086, 3922, 969, 18, 2015, 1067, 550, 2931, 2074, 3852, 2874, 3402, 2347, 3756, 680, 2121, 434, 1575, 3487, 2512, 3033, 3972,
    2664, 1140, 1836, 3042, 3666, 1996, 4052, 1748, 669, 1971, 3388, 2976, 2429, 603, 4070, 1170, 2516, 296, 2198, 3028, 1960, 1125, 2546, 3765, 1027, 3188, 59, 3658, 1730, 918, 3771, 2522,
    633, 3989, 2354, 1870, 2679, 1148, 2199, 2907, 2478, 3591, 3050, 375, 2403, 3636, 1410, 2553, 3196, 1600, 954, 91, 1550, 754, 1303, 3118, 1888, 3629, 2911, 2297, 905, 1959, 133, 1678,
    813, 2186, 45, 1455, 1036, 723, 1381, 2842, 3225, 1053, 162, 1369, 2016, 3314, 48, 1819, 3254, 3890, 1573, 746, 3451, 1470, 3267, 301, 1898, 1443, 2052, 2535, 449, 2896, 2237, 1091,
    1803, 2928, 439, 3725, 3268, 751, 1528, 3418, 1821, 110, 1595, 1256, 2942, 1826, 705, 4090, 212, 3736, 2434, 3327, 1922, 4036, 230, 2499, 978, 295, 1207, 4080, 536, 2834, 3777, 2333,
    3285, 3694, 2779, 3482, 2290, 2673, 3573, 354, 2340, 3654, 2661, 3870, 879, 1589, 2801, 2316, 956, 499, 2596, 3770, 246, 2802, 2101, 871, 2981, 544, 3961, 808, 3379, 1339, 269, 3541,
    1474, 2574, 965, 1404, 280, 2439, 3860, 475, 951, 3175, 2175, 3790, 505, 3424, 2806, 2205, 1292, 1879, 639, 1185, 2714, 2235, 2962, 3509, 1648, 2695, 3250, 1837, 1373, 3382, 1025, 322,
    1321, 642, 1651, 487, 3182, 167, 2097, 1198, 1588, 596, 2140, 436, 3074, 3618, 740, 1341, 3504, 2056, 3152, 1288, 2395, 585, 4053, 1680, 3435, 2268, 1213, 3082, 1622, 3908, 2021, 3146,
    5, 3614, 2185, 3370, 1783, 2995, 2055, 1283, 2748, 3998, 770, 2616, 1052, 1647, 317, 1002, 3490, 2591, 3068, 3577, 344, 913, 1406, 597, 2100, 3906, 802, 182, 2590, 2127, 1610, 3091,
    2635, 2027, 4032, 999, 1873, 3892, 840, 3278, 3814, 2873, 1764, 1182, 2373, 1900, 324, 3963, 2915, 129, 1707, 863, 1882, 3616, 1202, 2579, 104, 3784, 2703, 312, 2349, 595, 2764, 853,
    4091, 1258, 577, 2702, 3956, 876, 54, 3667, 2292, 1472, 218, 3332, 2008, 2482, 3840, 3212, 497, 1654, 123, 2130, 3867, 1787, 3209, 3764, 6, 1478, 2401, 3122, 3831, 381, 3604, 777,
    3797, 206, 3024, 2449, 1272, 2902, 1693, 2384, 11, 953, 3174, 3997, 119, 2666, 3246, 1536, 2463, 1139, 3912, 2734, 3307, 179, 2961, 765, 1500, 1970, 941, 1807, 3648, 1143, 3312, 1694,
    2480, 2004, 3173, 214, 1160, 1655, 2620, 3233, 615, 1919, 3031, 1221, 3655, 89, 1428, 2088, 2980, 3988, 839, 1504, 2793, 474, 2540, 1195, 2853, 3423, 1010, 1978, 629, 1238, 2797, 1801,
    2370, 1430, 726, 3563, 273, 3397, 500, 2738, 1447, 3585, 2532, 622, 1314, 3733, 995, 459, 1999, 672, 3465, 385, 2116, 1567, 2294, 3553, 3135, 365, 3366, 2870, 90, 2606, 2142, 419,
    2940, 784, 1482, 3587, 2342, 3443, 406, 1799, 1040, 3477, 2358, 542, 2903, 929, 2737, 667, 1822, 1246, 2476, 3293, 1093, 3499, 1994, 794, 2272, 447, 3698, 1576, 2970, 2204, 3485, 36,
    1012, 3348, 2156, 1569, 2588, 1982, 780, 4082, 2157, 370, 1985, 1620, 3472, 2191, 1765, 3098, 3798, 2847, 2281, 1354, 820, 3987, 512, 1063, 2524, 2099, 4035, 1224, 1563, 3889, 959, 3467,
    180, 3847, 2644, 1934, 646, 3039, 1325, 4024, 2826, 260, 3859, 1539, 1857, 4046, 2279, 3580, 169, 2838, 3774, 612, 2289, 100, 4060, 1453, 3186, 1820, 2611, 124, 4033, 916, 1473, 2569,
    3968, 2852, 477, 3881, 1057, 3662, 1364, 2946, 1094, 3319, 848, 3069, 2805, 341, 756, 2561, 1190, 24, 1782, 3229, 2559, 2913, 1897, 3729, 1420, 467, 791, 2339, 3027, 579, 1868, 1358,
    2386, 1726, 1060, 359, 3923, 2128, 832, 2473, 2023, 1403, 883, 2608, 3353, 383, 1310, 3165, 1004, 2149, 340, 1874, 3130, 1628, 2966, 276, 3574, 704, 1304, 3292, 2382, 441, 3240, 2001,
    313, 1232, 1878, 2988, 71, 2244, 3202, 205, 1660, 2307, 3929, 175, 1122, 2426, 4014, 3279, 1617, 3547, 976, 3868, 267, 1242, 3364, 52, 2818, 3197, 1753, 3607, 300, 2188, 3695, 3153,
    546, 3621, 2864, 3257, 1419, 2740, 113, 3508, 557, 3716, 3147, 12, 2163, 772, 1745, 2497, 3926, 1525, 3407, 1277, 3703, 910, 2484, 1120, 2724, 2153, 3768, 1023, 1735, 2832, 696, 3689,
    1653, 2423, 3256, 870, 2677, 1752, 651, 2544, 3752, 547, 2649, 1531, 3652, 1955, 1370, 225, 2170, 563, 2759, 1974, 722, 2315, 1639, 907, 2225, 3849, 1087, 2660, 3338, 1255, 2727, 891,
    1497, 2216, 37, 1884, 947, 3702, 1734, 1156, 2956, 1682, 2308, 1217, 3755, 2951, 3545, 223, 631, 3047, 2425, 752, 2769, 431, 2034, 3911, 1486, 364, 2959, 224, 2083, 3579, 1197, 2694,
    935, 3821, 606, 3498, 1412, 3978, 3360, 1206, 1902, 3512, 1008, 2135, 3228, 472, 2875, 922, 3718, 3080, 2393, 1454, 3593, 3018, 3957, 2628, 623, 1520, 154, 1988, 727, 1657, 139, 3872,
    3114, 1204, 3470, 2443, 575, 3006, 2209, 2598, 315, 3428, 684, 2730, 1603, 994, 2072, 2749, 1145, 1954, 38, 4007, 2214, 1723, 3263, 635, 3476, 1846, 2419, 3949, 1384, 3170, 81, 2167,
    3086, 181, 1574, 2288, 305, 982, 2111, 374, 3084, 1446, 46, 2971, 712, 1667, 3825, 2531, 1786, 1179, 173, 3321, 488, 1102, 199, 1829, 3411, 2854, 3530, 2485, 3933, 2963, 2341, 1908,
    2785, 730, 3793, 1570, 3334, 256, 4051, 1479, 981, 3817, 2049, 213, 3946, 429, 3247, 1452, 3748, 3448, 1658, 2905, 1049, 3605, 107, 2641, 993, 3110, 515, 898, 2636, 640, 1690, 4067,
    1365, 2573, 1921, 3680, 3133, 2498, 2892, 3846, 828, 2720, 2321, 4048, 1273, 3430, 2267, 325, 3358, 778, 4081, 1850, 2811, 2195, 3696, 1270, 2089, 367, 1033, 1439, 490, 946, 3390, 411,
    1041, 2084, 356, 2684, 1061, 2044, 767, 3253, 1901, 2821, 1394, 3089, 2458, 1866, 745, 2299, 349, 2607, 664, 1374, 362, 3022, 1530, 2305, 1323, 3700, 1626, 3371, 1947, 3674, 2399, 422,
    3376, 798, 2949, 1092, 564, 1789, 146, 1582, 2036, 3455, 397, 1791, 2615, 195, 1084, 1494, 2768, 2092, 1319, 2550, 738, 1568, 2947, 530, 3204, 4042, 2365, 3040, 3650, 1818, 1349, 4068,
    3238, 1630, 2318, 3943, 1359, 2855, 3596, 50, 2445, 473, 880, 3394, 1188, 3590, 2916, 4086, 1024, 2104, 3141, 3853, 2433, 2009, 3970, 759, 2814, 187, 2215, 2917, 270, 998, 2871, 2041,
    1171, 3837, 250, 2075, 4028, 3415, 1261, 3660, 589, 1173, 3109, 920, 3668, 2032, 3097, 3938, 426, 3602, 3184, 77, 3877, 3365, 937, 2492, 1495, 810, 1749, 242, 2176, 2715, 63, 2430,
    573, 3581, 130, 3111, 620, 1725, 2306, 1254, 3011, 3990, 1751, 2258, 641, 56, 1685, 1334, 3363, 143, 1856, 845, 3335, 1172, 440, 3429, 1967, 3828, 626, 1194, 3992, 1542, 3459, 679,
    3178, 1669, 2680, 1380, 2350, 743, 2783, 2168, 2542, 3915, 1627, 2261, 545, 2831, 852, 1853, 2332, 668, 1637, 1064, 2270, 334, 1894, 3820, 7, 2735, 3420, 1193, 3192, 790, 3724, 1953,
    1397, 2513, 952, 1924, 3479, 373, 3855, 819, 1537, 3473, 186, 2689, 3843, 2078, 2774, 527, 2355, 3802, 2823, 1552, 222, 2700, 1746, 3090, 1076, 1496, 2404, 3211, 1890, 2562, 10, 1411,
    2446, 363, 3626, 3287, 55, 1728, 3148, 990, 332, 2884, 158, 3350, 1407, 3845, 20, 3266, 1192, 2566, 3037, 1980, 3571, 2681, 1184, 3063, 2262, 3659, 1958, 588, 3954, 1601, 1083, 2997,
    254, 3879, 2879, 1196, 2621, 2076, 3191, 2667, 526, 2030, 1080, 3155, 1386, 3449, 967, 3205, 1775, 1208, 580, 3519, 2247, 3691, 659, 2518, 68, 3539, 2746, 376, 781, 3566, 2133, 3783,
    2937, 1852, 766, 1045, 2592, 3876, 458, 3392, 1824, 1287, 3644, 2475, 1928, 1112, 2668, 1548, 3726, 293, 4012, 506, 1414, 3283, 720, 1640, 393, 949, 1390, 2923, 2405, 338, 2623, 3404,
    2181, 1713, 710, 3613, 1488, 102, 1070, 1666, 3795, 2926, 2451, 771, 1867, 284, 2560, 3645, 243, 3038, 2481, 1051, 1956, 2958, 1329, 4050, 2172, 892, 1721, 3899, 1343, 2841, 942, 514,
    1137, 3919, 2222, 3030, 1957, 1212, 1561, 2412, 4094, 2119, 822, 417, 3237, 653, 2295, 3452, 796, 1805, 2776, 927, 2447, 138, 3973, 2109, 3231, 2614, 3838, 172, 2080, 3546, 1865, 638,
    1266, 3249, 2385, 416, 3139, 4079, 2505, 3330, 239, 1305, 3575, 388, 4040, 2280, 1562, 652, 2150, 4010, 1481, 15, 3880, 854, 366, 1681, 3289, 525, 3100, 2274, 147, 3346, 1809, 2317,
    3262, 1477, 244, 3501, 578, 3637, 2862, 764, 82, 3101, 1517, 2809, 3986, 1706, 3029, 220, 2081, 1286, 3219, 2190, 3705, 1770, 2812, 1296, 3543, 518, 1585, 3168, 803, 1298, 2898, 4029,
    2565, 75, 3799, 1977, 881, 2246, 511, 1903, 939, 2256, 1712, 3300, 1168, 2934, 3751, 1282, 2803, 826, 3271, 2672, 1788, 3151, 2298, 2825, 1129, 3699, 1989, 1042, 2536, 1558, 4075, 201,
    2656, 693, 2787, 1629, 2438, 281, 2141, 3759, 1166, 2539, 3555, 1006, 2166, 391, 1336, 3622, 2836, 3865, 165, 1583, 558, 3117, 989, 268, 2413, 1886, 1050, 2555, 3745, 1742, 389, 903,
    3067, 1557, 1107, 2824, 1644, 3012, 1348, 3683, 2600, 3944, 614, 2682, 2006, 860, 78, 3160, 1675, 2003, 328, 3631, 567, 1396, 3491, 117, 2564, 1513, 263, 2941, 3670, 486, 3043, 1249,
    3526, 2029, 3977, 1159, 3308, 885, 1445, 3177, 1747, 539, 1943, 189, 2657, 3767, 869, 2418, 531, 1047, 2572, 3494, 1250, 2502, 2047, 3824, 811, 2943, 4083, 2124, 43, 3315, 2345, 3598,
    605, 2148, 3377, 632, 3883, 159, 3466, 697, 2887, 25, 1476, 3132, 339, 2496, 3445, 2227, 468, 3785, 1165, 2137, 2538, 1011, 3804, 2038, 792, 3878, 3356, 706, 1315, 2171, 821, 2420,
    1720, 984, 41, 3052, 1825, 3856, 2510, 386, 3496, 2894, 3861, 1219, 3288, 1793, 3164, 1490, 1975, 3378, 1761, 823, 4025, 60, 3351, 1424, 3206, 360, 1340, 643, 2863, 992, 1429, 1892,
    2800, 3761, 292, 2646, 1269, 2112, 2453, 1784, 1180, 2057, 3432, 1071, 3888, 1612, 1201, 3993, 950, 2461, 3060, 1527, 3345, 274, 1816, 2987, 1243, 2266, 1704, 2757, 1911, 3269, 3813, 299,
    2965, 3681, 2554, 645, 2208, 178, 2816, 1035, 2077, 785, 2390, 1532, 570, 2304, 101, 2718, 3960, 277, 3072, 2218, 2867, 1880, 654, 2692, 1738, 2229, 3367, 3619, 1927, 2460, 3975, 192,
    1074, 1401, 2379, 1831, 3524, 856, 3275, 390, 3019, 3782, 2388, 753, 1940, 2993, 608, 2743, 1812, 3514, 97, 779, 4065, 2704, 663, 3277, 455, 2632, 355, 3995, 58, 960, 2617, 1342,
    602, 2082, 1465, 3474, 1233, 3600, 1594, 4018, 1368, 29, 3414, 2968, 4055, 1128, 3481, 761, 1237, 2469, 627, 1362, 404, 3540, 1114, 3769, 216, 2578, 1100, 1611, 283, 3103, 701, 3355,
    2053, 3167, 749, 3959, 443, 2848, 1456, 4044, 957, 1634, 237, 2658, 3690, 121, 2102, 3291, 321, 1372, 2851, 2357, 1741, 1147, 2241, 3901, 1633, 3588, 1079, 3144, 2353, 1609, 3426, 1869,
    4026, 3198, 358, 2886, 795, 2421, 496, 3131, 2284, 2711, 1662, 945, 287, 1893, 2845, 2155, 3610, 1686, 3298, 3835, 2609, 1619, 2114, 3041, 928, 3971, 532, 2755, 3811, 1234, 1732, 2548,
    3866, 9, 1689, 3001, 1059, 2050, 115, 2577, 2212, 587, 3286, 1780, 1259, 3438, 1449, 2551, 884, 3925, 2019, 470, 3150, 3542, 33, 1331, 2815, 736, 2024, 1360, 3710, 634, 2839, 211,
    2471, 1032, 1695, 3895, 2010, 3342, 1777, 859, 3773, 400, 3594, 2113, 2514, 3738, 1463, 420, 2989, 3, 1058, 1963, 855, 3227, 105, 2440, 1535, 1961, 3226, 2319, 824, 2136, 3515, 484,
    915, 2640, 3457, 1337, 2530, 3794, 1760, 3564, 3064, 1355, 3743, 2880, 450, 2250, 742, 3628, 1697, 3073, 1097, 3663, 1506, 865, 2545, 1932, 3207, 249, 2437, 2938, 395, 2177, 1169, 3556,
    741, 2242, 2712, 94, 1352, 2645, 193, 2939, 1186, 1930, 691, 3162, 1307, 630, 3259, 966, 1843, 3779, 2376, 2878, 326, 4059, 1251, 3688, 716, 3493, 252, 1418, 3035, 132, 2857, 1546,
    3642, 1945, 561, 2236, 319, 3304, 725, 1136, 306, 1933, 835, 2409, 1115, 4085, 2766, 286, 2283, 598, 2594, 198, 2196, 2895, 537, 3741, 906, 4016, 1722, 3436, 997, 3941, 1759, 3048,
    1421, 3706, 3255, 648, 3624, 955, 3979, 2134, 3380, 1507, 2883, 3953, 79, 2696, 2259, 4005, 2575, 1382, 538, 3557, 1555, 2568, 2202, 427, 2921, 2662, 1046, 3763, 1842, 4015, 1133, 2293,
    2780, 1209, 4066, 3189, 964, 1614, 2861, 2291, 3385, 2638, 3920, 39, 3138, 1577, 1918, 3216, 1274, 3744, 1851, 3190, 3994, 1226, 3326, 1547, 2233, 1211, 2604, 122, 1559, 3156, 2528, 30,
    2095, 425, 1152, 1962, 3055, 2303, 1621, 549, 2605, 233, 2400, 1038, 1774, 3492, 1554, 190, 782, 3437, 2192, 1174, 3102, 801, 1841, 3199, 1371, 1781, 2245, 478, 2599, 677, 3328, 302,
    744, 1671, 145, 2813, 2066, 3887, 72, 3669, 1492, 551, 1668, 2152, 3529, 507, 908, 3850, 103, 2829, 968, 1597, 719, 1969, 128, 2772, 372, 3106, 699, 3638, 2213, 523, 842, 3801,
    2741, 1683, 4078, 2520, 1471, 357, 3523, 1088, 3858, 809, 3625, 2070, 560, 2998, 1142, 2058, 3116, 2705, 275, 1929, 3921, 168, 3486, 970, 3965, 153, 3656, 3129, 1607, 2174, 1363, 3044,
    3815, 2407, 3484, 1378, 665, 2486, 1235, 1987, 889, 3217, 2828, 1013, 1366, 2994, 2583, 2120, 1491, 2368, 3468, 368, 2557, 3623, 2344, 3433, 1767, 3841, 1966, 2835, 1149, 3395, 1887, 1280,
    3462, 936, 2944, 203, 833, 3224, 2736, 1941, 3099, 1691, 1317, 3306, 2533, 3810, 438, 3603, 1744, 1029, 3787, 709, 2362, 2856, 1516, 2624, 591, 2414, 1275, 775, 3489, 51, 3611, 1861,
    398, 2722, 1043, 1906, 2984, 3578, 464, 2761, 4043, 248, 2276, 3809, 176, 1737, 3583, 734, 3248, 541, 2000, 3836, 3026, 943, 1379, 616, 1030, 2448, 1417, 430, 4039, 2408, 2935, 303,
    2325, 582, 2159, 3427, 1862, 3927, 1300, 14, 2361, 492, 2844, 131, 919, 1457, 2804, 2380, 566, 3329, 1613, 3020, 1312, 462, 2105, 3727, 1883, 3323, 2837, 1983, 1095, 2691, 2335, 986,
    3316, 2107, 555, 3967, 253, 1677, 3154, 2322, 1415, 1854, 637, 3347, 2500, 2026, 330, 1203, 4037, 2910, 1099, 1440, 202, 1811, 4074, 2922, 3544, 42, 3214, 894, 1754, 144, 1462, 3924,
    3119, 1593, 3723, 1034, 2610, 552, 2238, 932, 3422, 3719, 1806, 3964, 2286, 1931, 228, 4084, 1367, 2206, 84, 2472, 3521, 851, 3222, 40, 1037, 1549, 291, 4095, 3087, 457, 3891, 1584,
    125, 3632, 1505, 3201, 2228, 1161, 737, 3502, 1056, 3686, 3017, 1245, 844, 3904, 3127, 2659, 1711, 1, 2490, 3354, 2226, 2707, 437, 2139, 1553, 2648, 2028, 3601, 2760, 3340, 1009, 1976,
    414, 2698, 1268, 95, 3163, 1676, 3760, 3032, 1469, 2558, 1154, 676, 3232, 3537, 1090, 3051, 831, 2751, 3862, 1055, 1817, 4038, 1387, 2960, 2470, 3796, 621, 2375, 1729, 1338, 758, 2927,
    2487, 1252, 2795, 868, 2576, 3854, 2046, 184, 2670, 435, 2110, 1635, 2807, 522, 1400, 2264, 812, 3735, 1849, 554, 3608, 807, 3176, 1214, 308, 3907, 732, 1302, 2158, 607, 2515, 3678,
    793, 3368, 2090, 4009, 1402, 2464, 278, 1990, 750, 174, 2132, 2728, 1608, 521, 2503, 1763, 3480, 448, 1948, 3128, 238, 2603, 2217, 717, 3507, 2017, 2790, 930, 3646, 2197, 3264, 1979,
    4030, 412, 1800, 3720, 53, 1432, 2889, 3290, 1578, 2431, 3976, 49, 3471, 1920, 3640, 279, 3387, 2798, 1001, 3059, 1309, 1664, 3822, 2543, 3361, 1785, 2929, 200, 3803, 1645, 2881, 1223,
    2301, 1708, 335, 2909, 739, 3559, 1138, 2808, 4056, 3171, 3649, 351, 2991, 1353, 3788, 149, 2161, 1436, 3639, 674, 1599, 3401, 493, 1776, 1216, 209, 1461, 3386, 98, 2663, 348, 1127,
    817, 3076, 2356, 656, 3341, 1916, 568, 991, 3651, 670, 1144, 3221, 2338, 924, 2589, 1132, 1592, 2165, 232, 4004, 2396, 118, 2045, 1054, 489, 2348, 926, 3185, 2428, 446, 3410, 23,
    3075, 3839, 1005, 2346, 1838, 3066, 540, 1632, 2366, 1327, 1872, 1007, 3934, 2255, 882, 2930, 3242, 1124, 2669, 2243, 2882, 1181, 3766, 3036, 2563, 3999, 3140, 1881, 1241, 3914, 1602, 3375,
    1909, 3584, 1534, 2955, 1117, 2527, 4077, 2251, 2996, 1899, 2732, 1493, 442, 1724, 3996, 3045, 592, 3781, 1236, 1910, 2918, 3528, 675, 3085, 3693, 1383, 4047, 1973, 1121, 1468, 3966, 1896,
    657, 1413, 2786, 3488, 207, 3931, 2145, 3399, 378, 834, 2650, 3295, 1701, 290, 2630, 1855, 590, 3894, 31, 962, 3962, 323, 2063, 902, 396, 2151, 830, 508, 2468, 3016, 576, 2273,
    76, 1297, 329, 2068, 3780, 409, 1727, 156, 1326, 350, 3875, 799, 3664, 2868, 194, 1944, 2444, 3273, 2747, 528, 904, 1475, 2652, 1740, 2183, 70, 2642, 593, 3302, 2763, 901, 2219,
    2593, 3612, 495, 1646, 886, 1375, 2697, 1026, 2948, 3554, 114, 2329, 698, 3532, 1178, 3373, 1533, 2387, 1926, 3061, 1487, 2509, 1718, 3234, 3599, 1556, 2877, 3778, 2065, 985, 3635, 2731,
    3183, 3851, 2817, 921, 3447, 1416, 2726, 3272, 3536, 2311, 3112, 2039, 2489, 1239, 3511, 877, 1408, 304, 1717, 2327, 3200, 3913, 320, 3425, 1155, 2992, 1581, 3558, 215, 1813, 3704, 361,
    3235, 1098, 2067, 2494, 3311, 1946, 44, 3826, 1590, 2043, 3885, 1441, 3095, 2025, 4031, 183, 2833, 3687, 428, 3362, 721, 3522, 120, 2742, 1081, 2378, 0, 3450, 1444, 240, 1739, 1163,
    600, 2220, 1625, 2442, 647, 3143, 2138, 931, 559, 1674, 1068, 83, 1604, 609, 3142, 2182, 3932, 3441, 1065, 3682, 34, 2115, 979, 2415, 502, 3833, 847, 2108, 2501, 673, 2950, 1247,
    1700, 92, 4092, 2872, 347, 3740, 2296, 703, 2549, 1199, 583, 2706, 1044, 424, 2441, 1395, 773, 1078, 1641, 2701, 1215, 2282, 3819, 1399, 572, 3871, 1833, 925, 2791, 3241, 4061, 2556
};


/* ============================================================================
   Ordered dither
   ========================================================================= */

constant float dovi_bayer_8x8[64] = {
     0.0f/64.0f, 32.0f/64.0f,  8.0f/64.0f, 40.0f/64.0f,  2.0f/64.0f, 34.0f/64.0f, 10.0f/64.0f, 42.0f/64.0f,
    48.0f/64.0f, 16.0f/64.0f, 56.0f/64.0f, 24.0f/64.0f, 50.0f/64.0f, 18.0f/64.0f, 58.0f/64.0f, 26.0f/64.0f,
    12.0f/64.0f, 44.0f/64.0f,  4.0f/64.0f, 36.0f/64.0f, 14.0f/64.0f, 46.0f/64.0f,  6.0f/64.0f, 38.0f/64.0f,
    60.0f/64.0f, 28.0f/64.0f, 52.0f/64.0f, 20.0f/64.0f, 62.0f/64.0f, 30.0f/64.0f, 54.0f/64.0f, 22.0f/64.0f,
     3.0f/64.0f, 35.0f/64.0f, 11.0f/64.0f, 43.0f/64.0f,  1.0f/64.0f, 33.0f/64.0f,  9.0f/64.0f, 41.0f/64.0f,
    51.0f/64.0f, 19.0f/64.0f, 59.0f/64.0f, 27.0f/64.0f, 49.0f/64.0f, 17.0f/64.0f, 57.0f/64.0f, 25.0f/64.0f,
    15.0f/64.0f, 47.0f/64.0f,  7.0f/64.0f, 39.0f/64.0f, 13.0f/64.0f, 45.0f/64.0f,  5.0f/64.0f, 37.0f/64.0f,
    63.0f/64.0f, 31.0f/64.0f, 55.0f/64.0f, 23.0f/64.0f, 61.0f/64.0f, 29.0f/64.0f, 53.0f/64.0f, 21.0f/64.0f
};

// Function constant 0: the blue-noise dither (DOVI_DITHER_BLUE_NOISE) compiled in. The default pipelines are
// specialised with it false, so the ordered-dither path carries no mode test: testing dither_mode there at run
// time measured +2.5% UHD GPU time on an M4 Pro (0.743 -> 0.762 ms), with no blue-noise frame in sight.
constant bool dovi_fc_blue_noise [[function_constant(0)]];

// Function constant 1: the MMR sums kept as two exact words throughout (`dovi_acc_add`), for a frame with a piece the
// float estimate cannot pin; false, the default, takes the estimate path for every piece. Chosen per frame by the
// composer (`populateMmrTable`), so neither pipeline carries the other's path.
constant bool dovi_fc_mmr_exact [[function_constant(1)]];

// Function constant 2: the luma kernel's MMR path, for a frame whose luma curve has an MMR piece (no profile 7
// stream seen has one). The default luma pipeline is the lookup table alone, so it carries none of the MMR's
// registers.
constant bool dovi_fc_luma_mmr [[function_constant(2)]];

// Function constant 3: the base layer alone, for a picture with no enhancement layer (Dolby Vision profile 5, AV1
// profile 10.0). The reconstruction is the prediction (h = v, CCM 001 5.4.3.3 with no residual), so these pipelines
// take neither the enhancement layer nor its inverse-NLQ table, and carry none of their reads or registers.
constant bool dovi_fc_base_only [[function_constant(3)]];
constant bool dovi_fc_with_el = !dovi_fc_base_only;

// Blue-noise threshold in [0.5/4096, 4095.5/4096]: rank k of the 4096 cells maps to (k + 0.5) / 4096, so the
// mean over the tile is exactly 0.5, the rounding bias of the undithered branch. A 10-bit code plus the
// threshold needs 10 + 13 bits, inside float's 24, so floor(v + d) is exact. Each component reads the tile at
// its own toroidal offset (Bayer phases (0,0) / (1,0) / (1,1) become (0,0) / (32,0) / (48,32)),
// each pair at least half a tile apart along one axis, where a blue-noise map is uncorrelated with itself.
static inline float dovi_blue_noise(uint2 gid, uint2 phase) {
    uint2 o = uint2(phase.x * 32u + phase.y * 16u, phase.y * 32u);
    uint x = (gid.x + o.x) & 63u;
    uint y = (gid.y + o.y) & 63u;
    return (float(dovi_blue_noise_64[y * 64u + x]) + 0.5f) * (1.0f / 4096.0f);
}

// Ordered dither offset in [0.5/64, 63.5/64], whose mean over the cell is
// exactly 0.5 -- the same rounding bias the undithered branch applies.
//
// The raw Bayer table holds k/64 for k in 0..63 and averages 31.5/64 = 0.4921875,
// 1/128 of a code low. That bias is invisible at any bit depth a Dolby Vision
// stream can ask for: the value reaching the rounding step has a fraction of
// j/vdr_scale, and for vdr_scale <= 64 the raw and centred tables select exactly
// the same cells at every j, so 10-bit BL into 12-bit VDR (vdr_scale = 4) is
// bit-identical either way. It becomes visible only at the vdr_scale >= 128 that
// setBitDepths still accepts, where the raw table's worst per-level error is
// 0.0117 codes against the centred table's 0.0078. Centring costs one add, makes
// the mean exactly 0.5 as claimed, and removes the case where it would matter.
//
// phase translates the cell so that two components written from the same value do
// not receive the same pattern. Not every translation does that: this matrix
// satisfies M[(y + 4) % 8][(x + 4) % 8] == M[y][x] +/- 1, so the (4, 4) diagonal
// is its own near-symmetry (a Cr phase there leaves Cb and Cr disagreeing on
// an average of 1 pixel in 64 -- at the 50% level, where the selected set is a
// checkerboard in (x + y) parity and a (4, 4) shift preserves parity, on zero
// pixels). Translations of odd parity are the ones that decorrelate, averaging 32
// pixels in 64. Parity is additive, so three mutually odd offsets do not exist;
// (0, 0) / (1, 0) / (1, 1) makes the two chroma components and the luma-Cb pair
// odd and leaves luma-Cr, which is also the pair that differs in plane and in
// resolution, at 16 in 64.
//
// The blue-noise pipelines (function constant `dovi_fc_blue_noise`) take the threshold from the 64x64
// blue-noise rank map instead (`dovi_blue_noise`): the same mean, its error pushed to high spatial
// frequencies rather than onto the Bayer grid's fixed periods, and static from frame to frame.
static inline float dovi_dither(uint2 gid, uint frame_index, uint2 phase) {
    if (dovi_fc_blue_noise) {
        return dovi_blue_noise(gid, phase);
    }
    uint dx = (gid.x + phase.x) % 8u;
    uint dy = (gid.y + phase.y) % 8u;
    float d = dovi_bayer_8x8[dy * 8u + dx];
    if (frame_index & 1u) {
        // Inversion is over the raw table, so the frame pair still covers every
        // cell exactly once; the half-step is added to both frames afterwards.
        d = (63.0f / 64.0f) - d;
    }
    return d + (0.5f / 64.0f);
}

/* ============================================================================
   Reshaping curve evaluation
   ========================================================================= */

// The composition arithmetic is Dolby's integer fixed point:
// - a base-layer value s enters as t = s << (20 - BL_bit_depth), Q20 of s / 2^BL_bit_depth, and a product of two
//   terms is taken back to Q20 with >> 20. For integer s that is the reference's own term (s0 * s1 <<
//   (20 - 2 * BL_bit_depth) is (t0 * t1) >> 20 exactly);
// - a prediction v is the 16-bit `vv >> (4 + coefficient_log2_denom)`, negative sums 0, capped at 0xffff;
// - the residual r is the 16-bit inverse NLQ (`DoviFelComposer.inverseNlq`, tabulated per EL code);
// - v + r is kept whole until the output is written (dovi_reconstruct and the writers below).

// Q20 shift for a base-layer code: 20 - BL_bit_depth.
static inline uint dovi_q20_shift(uint bl_max) {
    return 20u - (32u - clz(bl_max));
}

// The arithmetic is 64-bit integers, carried in 32-bit words, which Apple GPUs multiply natively where
// 64-bit integers are emulated:
// - every term is non-negative and below 2^20 (a clamped base-layer value in Q20, or a product of two), so a product
//   of two is below 2^40 and (a * b) >> 20 is its high word shifted up by 12 and its low word down by 20, exactly;
// - a sum of coefficient * term (a signed 32-bit coefficient times a term below 2^20) is a two-word accumulator,
//   each product's words from mul and the signed mulhi, the carry added by hand: int64 arithmetic, wrapping
//   included.

// (a * b) >> 20 for a * b below 2^52.
static inline uint dovi_mul_q20(uint a, uint b) {
    return (mulhi(a, b) << 12) | ((a * b) >> 20);
}

// A 64-bit sum as its high (signed) and low words.
struct DoviAcc {
    int hi;
    uint lo;
};

// constant << 20, the constant term: the coefficient against the term 1.0 in Q20 (`poly_coef[0] * (1 << 20)`).
static inline DoviAcc dovi_acc_constant(int c) {
    return DoviAcc{ c >> 12, uint(c) << 20 };
}

// acc += c * t, for 0 <= t < 2^31.
static inline void dovi_acc_add(thread DoviAcc &acc, int c, uint t) {
    uint lo = uint(c) * t;
    int hi = mulhi(c, int(t));
    uint sum = acc.lo + lo;
    acc.hi += hi + (sum < lo ? 1 : 0);
    acc.lo = sum;
}

// The accumulated Q(20 + coefficient_log2_denom) sum to the 16-bit prediction: negative sums 0,
// `>> (4 + coefficient_log2_denom)`, capped at 0xffff. The shift is held below 64, where a hostile coef_shift would
// otherwise leave it undefined.
static inline int dovi_prediction(DoviAcc acc, uint coef_shift) {
    if (acc.hi < 0) {
        return 0;
    }
    uint k = min(4u + coef_shift, 63u);
    uint hi = uint(acc.hi);
    if (k >= 32u) {
        return int(min(hi >> (k - 32u), 0xffffu));
    }
    if ((hi >> k) != 0u) {
        return 0xffff;   // at least 2^32 after the shift
    }
    return int(min((hi << (32u - k)) | (acc.lo >> k), 0xffffu));
}

// Index of the piece owning t: the last pivot that t reaches. The reference takes the first piece whose next pivot
// is above s, which is the same piece, a zero-width piece (two equal pivots) included: both give the later one. Past
// the last pivot the reference's index runs one beyond the pieces; the value is clamped to that pivot anyway, so the
// last piece is the one that applies.
static inline int dovi_select_piece(constant struct DoviPolynomialParams &curve, uint t, uint shift) {
    int last_piece = int(curve.num_pivots) - 2;
    int piece = 0;
    for (int i = 0; i <= last_piece; ++i) {
        if (t >= (curve.pivots[i] << shift)) {
            piece = i;
        }
    }
    return clamp(piece, 0, max(last_piece, 0));
}

// t clamped to a component's pivot range, in Q20 (the polynomial's input and each MMR input s0 / s1 / s2). A
// component with no usable curve (num_pivots < 2) has no range and is left as is.
static inline uint dovi_clamp_to_pivots(constant struct DoviPolynomialParams &curve, uint t, uint shift) {
    if (curve.num_pivots < 2u) {
        return t;
    }
    return clamp(t, curve.pivots[0] << shift, curve.pivots[curve.num_pivots - 1u] << shift);
}

// Polynomial piece: the sum of poly_coef[i] * s^i at Q20, i <= 2.
static inline int dovi_eval_poly(constant struct DoviPolynomialParams &curve, int piece, uint t, uint shift) {
    t = dovi_clamp_to_pivots(curve, t, shift);
    DoviAcc acc = dovi_acc_constant(curve.coef[piece][0]);
    uint order = curve.order[piece];
    if (order >= 1u) {
        dovi_acc_add(acc, curve.coef[piece][1], t);
    }
    if (order >= 2u) {
        dovi_acc_add(acc, curve.coef[piece][2], dovi_mul_q20(t, t));
    }
    return dovi_prediction(acc, curve.coef_shift[piece]);
}

// One component's MMR sum. The sum vv is a 64-bit integer. On the estimate path (`dovi_fc_mmr_exact` false) its low
// word is exact from wrapping 32-bit multiply-adds, one multiply per coefficient, and its high word is pinned by a
// float estimate E of the same sum, the coefficients' float values against the exact terms (every term is below
// 2^24, so its float value is exact; each coefficient's float value is converted where it is used, the same rounding
// the CPU's bound assumes): with A = sum of |c * t|, E is within (n + 2) * 2^-24 * A of vv in whatever order the
// terms are added, and for A <= 2^49 that is under 2^31, so hi = rint((E - lo) / 2^32) is vv's high word exactly. The
// CPU bounds A for every piece the frame can reach with the term ceiling 2^20; a frame with a piece it cannot bound
// gets the exact pipelines, which carry both words through two-word products for any coefficient. Either way the
// sum does not depend on the order its terms arrive in, and a zero coefficient or a zero term adds exactly nothing.
struct DoviMmrSum {
    DoviAcc acc;
    float e;
};

// Coefficient c against the term t (Q20; the constant is coefficient 0 against 1 << 20, 1.0).
static inline void dovi_mmr_add(thread DoviMmrSum &s, int c, uint t) {
    if (dovi_fc_mmr_exact) {
        dovi_acc_add(s.acc, c, t);
    } else {
        s.acc.lo += uint(c) * t;
        s.e = fma(float(c), float(t), s.e);
    }
}

// The sum's 16-bit prediction.
static inline int dovi_mmr_end(thread const DoviMmrSum &s, uint coef_shift) {
    if (dovi_fc_mmr_exact) {
        return dovi_prediction(s.acc, coef_shift);
    }
    int hi = int(rint((s.e - float(s.acc.lo)) * 0x1p-32f));
    return dovi_prediction(DoviAcc{ hi, s.acc.lo }, coef_shift);
}

// One term of a step of `dovi_mmr_shared`, its square and its cube (term * square), each product truncated back to
// Q20, against the coefficients the step's rotation has brought to lanes `first`, first + 8 and first + 16, of
// `a`'s piece and, with `Both`, `b`'s. Every lane takes part in the shuffles.
template <bool Both>
static inline void dovi_mmr_feed(thread DoviMmrSum &a, int ka, thread DoviMmrSum &b, int kb, ushort first,
                                 uint term) {
    uint square = dovi_mul_q20(term, term);
    uint cube = dovi_mul_q20(term, square);
    dovi_mmr_add(a, simd_shuffle(ka, first), term);
    dovi_mmr_add(a, simd_shuffle(ka, ushort(first + 8)), square);
    dovi_mmr_add(a, simd_shuffle(ka, ushort(first + 16)), cube);
    if (Both) {
        dovi_mmr_add(b, simd_shuffle(kb, first), term);
        dovi_mmr_add(b, simd_shuffle(kb, ushort(first + 8)), square);
        dovi_mmr_add(b, simd_shuffle(kb, ushort(first + 16)), cube);
    }
}

// The MMR sums of this sample's pieces, `piece_a` of `table_a` (and with `Both`, `piece_b` of `table_b`: Cb and Cr
// read the same three inputs), with the coefficients shared across the SIMD-group instead of every lane loading its
// own: in each pass the first lane still pending names a piece (pair), lane L loads coefficient L of it, and every
// term takes its coefficient from the lane holding it by shuffle. A lane whose pieces are the pass's sums its
// terms; any other sums zero terms, exactly nothing, and waits for a later pass. A group on one piece, as nearly
// every one is, takes one pass. `need` false (no MMR piece, or outside the picture) never counts as pending. Every
// lane of the SIMD-group must be here: the shuffles read every lane.
//
// A pass runs four steps, step i the subsets i and i + 4 (base and base * s2, the bases 1.0, s0, s1, s0s1): each
// reads its coefficients at lanes 0, 4, 8, 12, 16, 20 and then rotates them down a lane for the next. The steps are
// a loop the compiler keeps rolled, so a sample holds its inputs, the bases still to come, two sums a component and
// one step's six products, never the 21 terms (unrolled, the compiler forms them all up front and keeps them for
// the second component and the estimate).
template <bool Both>
static inline void dovi_mmr_shared(device const int* table_a, int piece_a, device const int* table_b, int piece_b,
                                   bool need, uint t0, uint t1, uint t2, uint lane,
                                   thread DoviMmrSum &a, thread DoviMmrSum &b) {
    a = DoviMmrSum{ DoviAcc{ 0, 0u }, 0.0f };
    b = DoviMmrSum{ DoviAcc{ 0, 0u }, 0.0f };
    bool pending = need;
    while (true) {
        uint waiting = uint(uint64_t(simd_ballot(pending)));
        if (waiting == 0u) {
            break;
        }
        ushort leader = ushort(ctz(waiting));
        int pass_a = simd_broadcast(piece_a, leader);
        int pass_b = Both ? simd_broadcast(piece_b, leader) : 0;
        bool mine = pending && piece_a == pass_a && (!Both || piece_b == pass_b);
        uint k = min(lane, uint(DOVI_MMR_TABLE_PIECE_STRIDE - 1));
        int ka = table_a[pass_a * DOVI_MMR_TABLE_PIECE_STRIDE + k];
        int kb = Both ? table_b[pass_b * DOVI_MMR_TABLE_PIECE_STRIDE + k] : 0;
        uint s0 = mine ? t0 : 0u, s1 = mine ? t1 : 0u, s2 = mine ? t2 : 0u;
        uint base = mine ? (1u << 20) : 0u, next = s0, after = s1, last = dovi_mul_q20(s0, s1);
        #pragma clang loop unroll(disable)
        for (ushort step = 0; step < 4; ++step) {
            dovi_mmr_feed<Both>(a, ka, b, kb, ushort(0), base);
            dovi_mmr_feed<Both>(a, ka, b, kb, ushort(4), dovi_mul_q20(base, s2));
            ka = simd_shuffle_rotate_down(ka, ushort(1));
            if (Both) {
                kb = simd_shuffle_rotate_down(kb, ushort(1));
            }
            base = next;
            next = after;
            after = last;
        }
        pending = pending && !mine;
    }
}

// The MMR inputs of a sample: luma (downsampled to the chroma site) and the two chroma values, each
// clamped to its own component's pivots.
static inline void dovi_mmr_inputs(constant struct DoviMetalParams &params, uint t0, uint t1, uint t2, uint shift,
                                   thread uint &c0, thread uint &c1, thread uint &c2) {
    c0 = dovi_clamp_to_pivots(params.poly_y, t0, shift);
    c1 = dovi_clamp_to_pivots(params.poly_cb, t1, shift);
    c2 = dovi_clamp_to_pivots(params.poly_cr, t2, shift);
}

// The piece of `curve` that t falls in, found once per sample and handed to everything that reads it; -1 for a curve
// with no usable pivots (num_pivots < 2), which is identity.
static inline int dovi_curve_piece(constant struct DoviPolynomialParams &curve, uint t, uint shift) {
    return curve.num_pivots < 2u ? -1 : dovi_select_piece(curve, t, shift);
}

// Whether `curve`'s `piece` is MMR (piece -1, identity, is not).
static inline bool dovi_is_mmr(constant struct DoviPolynomialParams &curve, int piece) {
    return piece >= 0 && curve.method[piece] == DOVI_MAPPING_MMR;
}

// One component's 16-bit prediction from its own value t (Q20), in a `piece` (`dovi_curve_piece`) that is not MMR (an
// MMR piece's is `dovi_mmr_end`). Piece -1, num_pivots < 2, is the parser's fail-safe for a curve it could not
// trust, and means identity: the base layer passes through untouched (v = s << (16 - BL_bit_depth), the identity
// polynomial's exact value).
static inline int dovi_eval_curve(constant struct DoviPolynomialParams &curve, int piece, uint t, uint shift) {
    if (piece < 0) {
        return int(min(t >> 4, 0xffffu));
    }
    return dovi_eval_poly(curve, piece, t, shift);
}

/* ============================================================================
   Inverse NLQ
   ========================================================================= */

// The inverse linear-deadzone quantiser depends on the EL code alone, so the composer evaluates it once per frame
// for every code of each component (`DoviFelComposer.inverseNlq`) and the kernels index that table:
// nlq_lut[component * DOVI_NLQ_LUT_CODES + code], the 16-bit signed r, Y then Cb then Cr. It runs past the 10-bit
// range because the EL upsampling filters overshoot (0 ... about 1400 from 10-bit input) and the inverse NLQ takes
// the upsampled code as it is.
#define DOVI_NLQ_LUT_CODES 2048
static inline int dovi_inv_nlq(device const int* nlq_lut, uint component, int el_code) {
    return nlq_lut[component * uint(DOVI_NLQ_LUT_CODES) + uint(clamp(el_code, 0, DOVI_NLQ_LUT_CODES - 1))];
}

/* ============================================================================
   Reconstruction and output
   ========================================================================= */

// h = v + r, still at 16 bits: the reconstruction rounds it once to hdr_bit_depth, and each writer below takes it
// from here, so no output is rounded twice.
//
// The reconstructed sample, hdr_bit_depth bits: (h + 2^(15 - hdr_bit_depth)) >> (16 - hdr_bit_depth), clipped to
// [0, 2^hdr_bit_depth - 1].
static inline int dovi_reconstruct(int h, uint vdr_max) {
    uint bits = 32u - clz(vdr_max);
    return clamp((h + (1 << (15u - bits))) >> (16u - bits), 0, int(vdr_max));
}

// The largest 16-bit sum the reconstruction does not clip: the one whose rounding to hdr_bit_depth bits is
// 2^hdr_bit_depth - 1 (65527 at 12 bits). A sum clipped to [0, dovi_sum_max] rounds to exactly the reconstruction's
// clipped sample, so the clip is the code space's, whatever range the picture is in. A depth the parser never
// accepts (outside 1...15 bits) still gives a bound within 16 bits.
static inline int dovi_sum_max(uint vdr_max) {
    uint bits = clamp(32u - clz(vdr_max), 1u, 15u);
    return min((int(vdr_max) << (16u - bits)) + (1 << (15u - bits)) - 1, 0xFFFF);
}

// 16-bit sample: h itself, clipped as the reconstruction is clipped (dovi_sum_max). A 10-bit code shifted left 6
// and a 12-bit code shifted left 4 are both h's scale (black 64 << 6 = 256 << 4 = 4096), so sv22 carries the sum
// before the reconstruction's rounding, from which its 12-bit sample is (h + 8) >> 4 exactly; P010's
// full-precision mode puts the same word in P010, whose low 6 bits CoreVideo calls padding.
static inline int dovi_full_precision(int h, uint vdr_max) {
    return clamp(h, 0, dovi_sum_max(vdr_max));
}

// h down to the 10-bit output plane, dithered or rounded, in one step from the 16-bit sum, clipped to the 10-bit code
// space as the reconstruction is clipped to its own.
static inline int dovi_quantize(
    int h,
    uint dither_mode,
    float dither)
{
    float v = float(h) * (1.0f / 64.0f);
    // Both branches have mean 0.5, so enabling dither redistributes the rounding
    // error without moving the average level.
    float bias = (dither_mode == DOVI_DITHER_NONE) ? 0.5f : dither;
    return clamp(int(floor(v + bias)), 0, 1023);
}

// A 4:2:0 chroma plane's size along an axis of `n` luma samples: half, rounded up, as CoreVideo allocates it, so an
// odd picture's last chroma column and row are read and written.
static inline uint dovi_chroma_size(uint n) {
    return (n + 1u) >> 1;
}

/* ============================================================================
   Enhancement layer upsampling
   ========================================================================= */

// The EL is brought to the base layer's grid by Dolby's reference resampling: the RPU carries no filter, so the
// reference is the only defined choice. Every 2:1 step takes the same grid: columns co-sited, rows centred.

// Vertical first, then horizontal, each pass rounded and clipped to [0, 0xFFFF], edges replicated:
// - vertical, luma (cmp 0): r[2n] = (-3 y[n-2] + 29 y[n-1] + 111 y[n] - 9 y[n+1] + 64) >> 7, r[2n+1] mirrored
//   (Catmull-Rom at the quarter phases, rows centred);
// - vertical, chroma (cmp 1, 2): r[2n] = (64 y[n-1] + 192 y[n] + 128) >> 8, r[2n+1] = (192 y[n] + 64 y[n+1] + 128) >> 8;
// - horizontal, every component (SPATIAL_RESAMPLING_FILTER_H): r[2n] = y[n], r[2n+1] = (22 y[n-3] + 94 y[n-2]
//   - 524 y[n-1] + 2456 y[n] + 2456 y[n+1] - 524 y[n+2] + 94 y[n+3] + 22 y[n+4] + 2048) >> 12 (columns co-sited).
//
// One SIMD-group composes the 32 consecutive output columns x0 ... x0 + 31, which read 23 EL columns (16, and 3 + 4
// neighbours for the 8 taps). Lane L runs the vertical pass for EL column x0 / 2 - 3 + L, and each output lane takes
// its horizontal taps from the lanes that hold them: registers and shuffles, no threadgroup memory, no barrier.
// Lanes 0 - 15 compose the even columns and lanes 16 - 31 the odd ones (`dovi_lane_column`), so that every tap is a
// fixed number of lanes away: a shuffle by a constant offset is one instruction, where one whose source lane varies
// inside a quad of lanes (lane L reading lane L / 2 + k) is four shuffles and three selects on the A15. That holds
// when lane L is grid column x0 + L: threadgroups 32 wide, dispatched in whole threadgroups, so every lane runs (the
// composer's `elUpsamplingThreadgroup`). Lanes past the picture still compute, on replicated edge columns, and only
// leave after the shuffles.

// The output column lane `lane` composes, in the SIMD-group whose first grid column is x0: x0 + 2L for lanes 0 - 15,
// x0 + 2(L - 16) + 1 for lanes 16 - 31.
static inline uint dovi_lane_column(uint x0, uint lane) {
    return x0 + ((lane & 15u) << 1) + (lane >> 4);
}

// The EL column lane `lane` runs the vertical pass for, edge replicated.
static inline int dovi_el_column(uint x0, uint lane, uint el_width) {
    return clamp(int(x0 >> 1) - 3 + int(lane), 0, int(el_width) - 1);
}

// Vertical pass, luma, for output row `row` at EL column `col`: the four EL rows it reads, from two gathers of the
// 2 x 2 block at (col, first) and (col, first + 2), this lane keeping column `col`; clamp-to-edge is the reference's
// replication.
static inline int dovi_el_v_luma(texture2d<ushort, access::sample> tex, int col, uint row) {
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    int n = int(row >> 1);
    bool odd = (row & 1u) != 0u;
    float first = float(odd ? n - 1 : n - 2);
    // Gather order: (x0, y1), (x1, y1), (x1, y0), (x0, y0).
    ushort4 a = tex.gather(s, float2(float(col) + 1.0f, first + 1.0f));
    ushort4 b = tex.gather(s, float2(float(col) + 1.0f, first + 3.0f));
    int y0 = int(a.w >> 6), y1 = int(a.x >> 6), y2 = int(b.w >> 6), y3 = int(b.x >> 6);
    int sum = odd ? (-9 * y0 + 111 * y1 + 29 * y2 - 3 * y3) : (-3 * y0 + 29 * y1 + 111 * y2 - 9 * y3);
    return clamp((sum + 64) >> 7, 0, 0xFFFF);
}

// Vertical pass, both chroma components, for BL chroma row `row` at EL chroma column `col`.
static inline int2 dovi_el_v_chroma(texture2d<ushort, access::read> tex, int col, uint row, uint el_height) {
    int n = int(row >> 1), last = int(el_height) - 1;
    bool odd = (row & 1u) != 0u;
    int2 a = int2(tex.read(uint2(col, clamp(odd ? n : n - 1, 0, last))).rg >> 6);
    int2 b = int2(tex.read(uint2(col, clamp(odd ? n + 1 : n, 0, last))).rg >> 6);
    int2 s = odd ? (192 * a + 64 * b) : (64 * a + 192 * b);
    return clamp((s + 128) >> 8, int2(0), int2(0xFFFF));
}

// Horizontal pass across the SIMD-group: `v` is this lane's vertical result. An even lane L (0 - 15, output column
// x0 + 2L) takes y[x0 / 2 + L], the co-sited value, from lane L + 3; an odd lane (16 - 31, output column
// x0 + 2(L - 16) + 1) takes its eight taps from lanes L - 16 ... L - 9. Every lane shuffles, whichever phase it keeps.
//
// The eight taps arrive as four pairs: every lane first takes its right neighbour's value beside its own (one
// shuffle down; each value is 16 bits, so the two fit a 32-bit word, Cb and Cr a word each), then an odd lane takes
// the pairs 16, 14, 12 and 10 lanes up. Six shuffles (ten for chroma's two components), each by a constant offset.
static inline int dovi_el_h_filter(int y0, int y1, int y2, int y3, int y4, int y5, int y6, int y7) {
    return clamp((22 * y0 + 94 * y1 - 524 * y2 + 2456 * y3 + 2456 * y4 - 524 * y5 + 94 * y6 + 22 * y7 + 2048) >> 12,
                 0, 0xFFFF);
}

static inline int dovi_el_h(int v, uint lane) {
    uint own = uint(v);
    uint even = simd_shuffle_down(own, ushort(3));
    uint pair = own | (simd_shuffle_down(own, ushort(1)) << 16);
    uint p0 = simd_shuffle_up(pair, ushort(16)), p1 = simd_shuffle_up(pair, ushort(14));
    uint p2 = simd_shuffle_up(pair, ushort(12)), p3 = simd_shuffle_up(pair, ushort(10));
    if (lane < 16u) {
        return int(even);
    }
    return dovi_el_h_filter(int(p0 & 0xFFFFu), int(p0 >> 16), int(p1 & 0xFFFFu), int(p1 >> 16),
                            int(p2 & 0xFFFFu), int(p2 >> 16), int(p3 & 0xFFFFu), int(p3 >> 16));
}

static inline int2 dovi_el_h(int2 v, uint lane) {
    uint own = uint(v.x) | (uint(v.y) << 16);
    uint even = simd_shuffle_down(own, ushort(3));
    uint2 pair = uint2(own, simd_shuffle_down(own, ushort(1)));
    uint2 p0 = simd_shuffle_up(pair, ushort(16)), p1 = simd_shuffle_up(pair, ushort(14));
    uint2 p2 = simd_shuffle_up(pair, ushort(12)), p3 = simd_shuffle_up(pair, ushort(10));
    if (lane < 16u) {
        return int2(int(even & 0xFFFFu), int(even >> 16));
    }
    int2 result;
    for (uint c = 0u; c < 2u; ++c) {
        uint shift = c * 16u;
        result[c] = dovi_el_h_filter(int((p0.x >> shift) & 0xFFFFu), int((p0.y >> shift) & 0xFFFFu),
                                     int((p1.x >> shift) & 0xFFFFu), int((p1.y >> shift) & 0xFFFFu),
                                     int((p2.x >> shift) & 0xFFFFu), int((p2.y >> shift) & 0xFFFFu),
                                     int((p3.x >> shift) & 0xFFFFu), int((p3.y >> shift) & 0xFFFFu));
    }
    return result;
}

// The upsampled EL luma code at this lane's BL pixel in row `row` (`dovi_lane_column`).
static inline int dovi_el_luma(texture2d<ushort, access::sample> tex, uint x0, uint row, uint lane, uint2 el_size) {
    return dovi_el_h(dovi_el_v_luma(tex, dovi_el_column(x0, lane, el_size.x), row), lane);
}

// The upsampled EL chroma codes (Cb, Cr) at this lane's BL chroma sample in row `row`.
static inline int2 dovi_el_chroma(texture2d<ushort, access::read> tex, uint x0, uint row, uint lane, uint2 el_size) {
    return dovi_el_h(dovi_el_v_chroma(tex, dovi_el_column(x0, lane, el_size.x), row, el_size.y), lane);
}

/* ============================================================================
   Composition kernels
   ========================================================================= */

// Whether the residual is added at luma column `x`: everywhere without a split, left of it with one.
static inline bool dovi_residual_at(constant struct DoviMetalParams &params, uint x) {
    return params.residual_split_x == 0u || x < params.residual_split_x;
}

// Luma: BL luma + reshaping curve + inverse-NLQ residual -> 10-bit P010 plane.
//
// bl_uv_tex is bound only because a luma curve may carry MMR pieces, which need
// all three components. No observed profile 7 stream has an MMR luma curve (libdovi
// would report it as mapping_idc = 1 for component 0), so only the `dovi_fc_luma_mmr`
// pipeline fetches it. There the chroma pair is taken
// nearest-neighbour from the 4:2:0 plane: the reshaping model is defined on 4:4:4
// input, and reconstructing chroma to full resolution here would cost a separate
// pass for a case that does not occur in practice.

kernel void dovi_compose_luma(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::sample>      el_y_tex      [[texture(2), function_constant(dovi_fc_with_el)]],
    texture2d<ushort, access::write>       out_y_tex     [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    constant int*                          luma_lut      [[buffer(1)]],
    device const int*                      nlq_lut       [[buffer(2), function_constant(dovi_fc_with_el)]],
    device const int*                      mmr_table     [[buffer(3)]],
    uint2                                  grid          [[thread_position_in_grid]],
    uint                                   lane          [[thread_index_in_simdgroup]])
{
    // This lane's pixel (`dovi_lane_column`); x0 is the first column of its SIMD-group's 32.
    uint x0 = grid.x - lane;
    uint2 gid = uint2(dovi_lane_column(x0, lane), grid.y);
    bool residual = dovi_fc_with_el && (params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u &&
                    params.nlq_y.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_y.nlq_scale != 0;
    // The EL's horizontal pass reads its neighbours' vertical results, so every lane runs it before any leaves.
    int el_code = 0;
    if (residual) {
        el_code = dovi_el_luma(el_y_tex, x0, gid.y, lane, uint2(params.el_width, params.el_height));
    }
    // A lane past the picture reads the edge and stays until the MMR's shuffles are done (they read every lane).
    bool inside = gid.x < params.bl_width && gid.y < params.bl_height;
    uint2 at = min(gid, uint2(params.bl_width - 1u, params.bl_height - 1u));

    int bl_y = int(bl_y_tex.read(at).r >> 6);

    int h;
    if (!dovi_fc_luma_mmr) {
        h = luma_lut[bl_y];
    } else {
        uint shift = dovi_q20_shift(params.bl_max);
        ushort4 bl_uv = bl_uv_tex.read(uint2(at.x >> 1, at.y >> 1));
        uint t = uint(bl_y) << shift;
        int piece = dovi_curve_piece(params.poly_y, t, shift);
        bool mmr = dovi_is_mmr(params.poly_y, piece);
        uint c0, c1, c2;
        dovi_mmr_inputs(params, t, uint(bl_uv.r >> 6) << shift, uint(bl_uv.g >> 6) << shift, shift, c0, c1, c2);
        // As in the chroma kernel: a polynomial piece first, on the clamped input.
        h = mmr ? 0 : dovi_eval_curve(params.poly_y, piece, c0, shift);
        DoviMmrSum sum, unused;
        dovi_mmr_shared<false>(mmr_table, piece, mmr_table, 0, inside && mmr, c0, c1, c2, lane, sum, unused);
        if (mmr) {
            h = dovi_mmr_end(sum, params.mmr_y.coef_shift);
        }
    }
    if (!inside) {
        return;
    }

    if (residual && dovi_residual_at(params, gid.x)) {
        h += dovi_inv_nlq(nlq_lut, 0u, el_code);
    }

    if (params.residual_split_x != 0u && uint(abs(int(gid.x) - int(params.residual_split_x))) < 2u) {
        h = 0x8000;   // the split's divider, mid-grey in PQ
    }

    if (params.dither_mode == DOVI_DEBUG_RAW_VDR) {
        out_y_tex.write(ushort4(ushort(dovi_reconstruct(h, params.vdr_max) << (16u - (32u - clz(params.vdr_max)))), 0, 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DITHER_FULL_PRECISION) {
        out_y_tex.write(ushort4(ushort(dovi_full_precision(h, params.vdr_max)), 0, 0, 0), gid);
        return;
    }
    int out_y = dovi_quantize(h, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(0u, 0u)));
    out_y_tex.write(ushort4(ushort(out_y << 6), 0, 0, 0), gid);
}

// Chroma: both chroma planes in one pass, since an MMR curve for Cb and for Cr
// reads the same three base-layer components. Composed at the 4:2:0 sites, where the reconstruction is defined;
// for sv22 (DOVI_FLAG_CHROMA_422) the result goes to the intermediate dovi_chroma_420_to_422 reads, not the output.
kernel void dovi_compose_chroma(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::read>        el_uv_tex     [[texture(2), function_constant(dovi_fc_with_el)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    device const int*                      nlq_lut       [[buffer(2), function_constant(dovi_fc_with_el)]],
    device const int*                      mmr_table     [[buffer(3)]],
    uint2                                  grid          [[thread_position_in_grid]],
    uint                                   lane          [[thread_index_in_simdgroup]])
{
    // This lane's chroma sample (`dovi_lane_column`); x0 is the first column of its SIMD-group's 32.
    uint x0 = grid.x - lane;
    uint2 gid = uint2(dovi_lane_column(x0, lane), grid.y);
    uint uv_width = dovi_chroma_size(params.bl_width);
    uint uv_height = dovi_chroma_size(params.bl_height);
    bool cb_active = params.nlq_cb.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cb.nlq_scale != 0;
    bool cr_active = params.nlq_cr.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cr.nlq_scale != 0;
    bool residual = dovi_fc_with_el && (params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u && (cb_active || cr_active);
    // As in the luma kernel: every lane runs the EL upsampling before any leaves.
    int2 el_code = int2(0);
    if (residual) {
        el_code = dovi_el_chroma(el_uv_tex, x0, gid.y, lane,
                                 uint2(dovi_chroma_size(params.el_width), dovi_chroma_size(params.el_height)));
    }

    // A lane past the picture reads the edge and stays until the MMR's shuffles are done (they read every lane).
    bool inside = gid.x < uv_width && gid.y < uv_height;
    uint2 at = min(gid, uint2(uv_width - 1u, uv_height - 1u));

    // Base-layer luma at the chroma site, for the cross-component terms: [1 2 1]
    // around the even column in each of the cell's two rows, then the rows
    // averaged, in integers, edges clamped. This is DoViBaker's reading, and
    // Dolby-encoded streams agree with it: on one with order-3 MMR chroma the
    // coded residual matches it at about half the error of the plain vertical
    // 2-tap this kernel used before.
    uint lx = min(at.x * 2u, params.bl_width - 1u);
    uint lxl = lx > 0u ? lx - 1u : 0u;
    uint lxr = min(lx + 1u, params.bl_width - 1u);
    int bl_y = 0;
    for (uint r = 0u; r < 2u; ++r) {
        uint ly = min(at.y * 2u + r, params.bl_height - 1u);
        int row = int(bl_y_tex.read(uint2(lxl, ly)).r >> 6)
                + 2 * int(bl_y_tex.read(uint2(lx, ly)).r >> 6)
                + int(bl_y_tex.read(uint2(lxr, ly)).r >> 6);
        bl_y += (row + 2) >> 2;
    }
    bl_y = (bl_y + 1) >> 1;

    ushort4 bl_uv = bl_uv_tex.read(at);
    int bl_cb = int(bl_uv.r >> 6);
    int bl_cr = int(bl_uv.g >> 6);

    uint shift = dovi_q20_shift(params.bl_max);
    uint t0 = uint(bl_y) << shift, t1 = uint(bl_cb) << shift, t2 = uint(bl_cr) << shift;
    int piece_cb = dovi_curve_piece(params.poly_cb, t1, shift), piece_cr = dovi_curve_piece(params.poly_cr, t2, shift);
    bool mmr_cb = dovi_is_mmr(params.poly_cb, piece_cb), mmr_cr = dovi_is_mmr(params.poly_cr, piece_cr);
    uint c0, c1, c2;
    dovi_mmr_inputs(params, t0, t1, t2, shift, c0, c1, c2);
    // A polynomial piece is evaluated before the MMR pass (on the clamped input, which it clamps to the same range), so
    // the pass carries one value a component rather than its piece and input.
    int h_cb = mmr_cb ? 0 : dovi_eval_curve(params.poly_cb, piece_cb, c1, shift);
    int h_cr = mmr_cr ? 0 : dovi_eval_curve(params.poly_cr, piece_cr, c2, shift);
    // One pass over the terms feeds both sums; a component whose piece is not MMR sums against the zero piece.
    DoviMmrSum sum_cb, sum_cr;
    dovi_mmr_shared<true>(mmr_table + DOVI_MMR_TABLE_COMPONENT_STRIDE, mmr_cb ? piece_cb : DOVI_MMR_ZERO_PIECE,
                          mmr_table + 2 * DOVI_MMR_TABLE_COMPONENT_STRIDE, mmr_cr ? piece_cr : DOVI_MMR_ZERO_PIECE,
                          inside && (mmr_cb || mmr_cr), c0, c1, c2, lane, sum_cb, sum_cr);
    if (mmr_cb) {
        h_cb = dovi_mmr_end(sum_cb, params.mmr_cb.coef_shift);
    }
    if (mmr_cr) {
        h_cr = dovi_mmr_end(sum_cr, params.mmr_cr.coef_shift);
    }
    if (!inside) {
        return;
    }

    if (residual && dovi_residual_at(params, gid.x * 2u)) {
        if (cb_active) {
            h_cb += dovi_inv_nlq(nlq_lut, 1u, el_code.x);
        }
        if (cr_active) {
            h_cr += dovi_inv_nlq(nlq_lut, 2u, el_code.y);
        }
    }

    // sv22: the 16-bit sums, clipped as the reconstruction is clipped, for the 4:2:2 step.
    if ((params.flags & DOVI_FLAG_CHROMA_422) != 0u) {
        out_uv_tex.write(ushort4(ushort(dovi_full_precision(h_cb, params.vdr_max)),
                                 ushort(dovi_full_precision(h_cr, params.vdr_max)), 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DEBUG_RAW_VDR) {
        uint up = 16u - (32u - clz(params.vdr_max));
        out_uv_tex.write(ushort4(ushort(dovi_reconstruct(h_cb, params.vdr_max) << up),
                                 ushort(dovi_reconstruct(h_cr, params.vdr_max) << up), 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DITHER_FULL_PRECISION) {
        out_uv_tex.write(ushort4(ushort(dovi_full_precision(h_cb, params.vdr_max)),
                                 ushort(dovi_full_precision(h_cr, params.vdr_max)), 0, 0), gid);
        return;
    }
    int out_cb = dovi_quantize(h_cb, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 0u)));
    int out_cr = dovi_quantize(h_cr, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 1u)));
    out_uv_tex.write(ushort4(ushort(out_cb << 6), ushort(out_cr << 6), 0, 0), gid);
}

// The 4:2:0 -> 4:2:2 taps, over chroma rows i - 1 ... i + 2 for a row at chroma-row coordinate i + t, by phase t in
// quarters, in 128ths:
// - t = 0, the chroma row itself: a copy, f[2n] = 64 s[n];
// - t = 1/2: (-1, 9, 9, -1) / 16, f[2n + 1] = -4 s[n - 1] + 36 s[n] + 36 s[n + 1] - 4 s[n + 2];
//   these two are Dolby's reference chroma up-sampling, for co-sited chroma;
// - t = 1/4, 3/4: Catmull-Rom at the quarter phases, the EL luma's vertical taps, for the other sitings.
constant int dovi_chroma_422_taps[4][4] = {
    {  0, 128,   0,   0 },
    { -9, 111,  29,  -3 },
    { -8,  72,  72,  -8 },
    { -3,  29, 111,  -9 },
};

// The vertical offset, in quarter chroma rows, of 4:2:2 row 2k from chroma row k, by the base layer's siting
// (AVChromaLocation in params.bl_chroma_loc):
// - LEFT / CENTER (chroma_sample_loc_type 0 / 1): chroma between luma rows 2k and 2k + 1, so row 2k is 1/4 above
//   chroma row k and row 2k + 1 1/4 below: -1.
// - TOPLEFT / TOP (types 2 / 3, what UHD Blu-ray and BT.2020 HEVC commonly signal): chroma on row 2k, so row 2k
//   is chroma row k and row 2k + 1 half way to k + 1: 0.
// - BOTTOMLEFT / BOTTOM (types 4 / 5): chroma on row 2k + 1, so row 2k is half way between k - 1 and k: -2.
// - UNSPECIFIED: HEVC infers type 0 when the VUI carries no chroma_loc_info, so LEFT. FFmpeg's HEVC decoder
//   already writes LEFT into the codec parameters in that case, so UNSPECIFIED reaches here only from a stream
//   FFmpeg did not probe.
static inline int dovi_chroma_422_offset_q(uint loc) {
    switch (loc) {
        case 3u: case 4u: return 0;
        case 5u: case 6u: return -2;
        default: return -1;
    }
}

// sv22's 4:2:0 -> 4:2:2 step, one thread per output sample: Dolby's reference vertical chroma up-sampling, on the
// reconstructed picture, after composition. `in_uv_tex` holds dovi_compose_chroma's 16-bit sums at the 4:2:0
// sites, clipped as the reconstruction is; each output row takes the four chroma rows around it at its phase
// (dovi_chroma_422_taps), edge rows replicated, rounded once, `+ 64 >> 7` (tvOS and the display take the 4:2:2
// picture's horizontal step), and clipped the same way.
// On a chroma row the output is that row's composed sum. The rows sit where the stream's siting puts them
// (dovi_chroma_422_offset_q); chroma is horizontally co-sited with the even luma column.
kernel void dovi_chroma_420_to_422(
    texture2d<ushort, access::read>        in_uv_tex     [[texture(0)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(1)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    uint uv_width = dovi_chroma_size(params.bl_width);
    if (gid.x >= uv_width || gid.y >= params.bl_height) {
        return;
    }
    // The row's chroma-row coordinate in quarters, q = 2 * row + offset (>= -2): whole part q / 4, phase q % 4.
    int q = 2 * int(gid.y) + dovi_chroma_422_offset_q(params.bl_chroma_loc) + 8;
    int first = q / 4 - 2 - 1;
    int phase = q & 3;
    int last_row = int(dovi_chroma_size(params.bl_height)) - 1;
    int2 sum = int2(0);
    for (int i = 0; i < 4; ++i) {
        uint row = uint(clamp(first + i, 0, last_row));
        sum += int2(in_uv_tex.read(uint2(gid.x, row)).rg) * dovi_chroma_422_taps[phase][i];
    }
    int2 h = (sum + 64) >> 7;
    out_uv_tex.write(ushort4(ushort(dovi_full_precision(h.x, params.vdr_max)),
                             ushort(dovi_full_precision(h.y, params.vdr_max)), 0, 0), gid);
}

/* ============================================================================
   IPT-PQ-c2 to BT.2020 Y'CbCr PQ (profile 5 and AV1 10.0 stills)
   ========================================================================= */

// The colour conversion a profile 5 picture carries in its RPU's display-management data (CCM 001 6.2.2), with the
// last step the RPU leaves implied:
// - ycc_to_lms: YCCtoRGB_coef, the opponent signal (here IPT, signal_color_space 2) to the non-linear trichromatic one,
//   applied after subtracting ycc_offset (YCCtoRGB_offset);
// - the ST 2084 EOTF on each component (signal_eotf: PQ);
// - lms_to_rgb: RGBtoLMS_coef (for IPT-PQ-c2, the inverse of its crosstalk) followed by LMS to linear BT.2020 RGB,
//   one matrix. Row major.
struct DoviIptConversion {
    float ycc_to_lms[9];
    float ycc_offset[3];
    float lms_to_rgb[9];
};

// e^x - 1 and log(1 + x), accurate for small x where the direct forms lose their digits to the subtraction (Kahan's
// formulations over precise exp and log). Reassociation off: it would fold (1 + x) - 1 back to x.
static inline float3 dovi_expm1(float3 x) {
    #pragma clang fp reassociate(off)
    float3 u = precise::exp(x);
    float3 um1 = u - 1.0f;
    float3 r = select(um1 * x / precise::log(u), x, u == 1.0f);
    return select(r, float3(-1.0f), um1 == -1.0f);
}

static inline float3 dovi_log1p(float3 x) {
    #pragma clang fp reassociate(off)
    float3 u = 1.0f + x;
    return select(precise::log(u) * x / (u - 1.0f), x, u == 1.0f);
}

// The ST 2084 curves, written so that nothing cancels: with p = 1 + d, p - c1 = (1 - c1) + d and c2 - c3 p =
// (c2 - c3) - c3 d, and the inverse's ratio (c1 + c2 p) / (1 + c3 p) is 1 + (c2 - c3) d / (1 + c3 p); 1 - c1 and
// c2 - c3 are both 0.1640625 exactly. In single precision the direct forms are off by up to 11 in 65535 at 16-bit
// video range; these, by a tenth of one.
static inline float3 dovi_pq_eotf(float3 e) {
    float3 d = dovi_expm1(precise::log(max(e, 1e-30f)) * (1.0f / 78.84375f));
    float3 ratio = max(0.1640625f + d, 0.0f) / (0.1640625f - 18.6875f * d);
    return select(precise::exp(precise::log(ratio) * (1.0f / 0.1593017578125f)), float3(0.0f), e <= 0.0f);
}

static inline float3 dovi_pq_oetf(float3 l) {
    float3 d = dovi_expm1(precise::log(max(l, 1e-30f)) * 0.1593017578125f);
    float3 encoded = precise::exp(78.84375f * dovi_log1p(0.1640625f * d / (1.0f + 18.6875f * (1.0f + d))));
    return select(encoded, float3(precise::pow(0.8359375f, 78.84375f)), l <= 0.0f);
}

static inline float3 dovi_mul3(constant float *m, float3 v) {
    return float3(m[0] * v.x + m[1] * v.y + m[2] * v.z,
                  m[3] * v.x + m[4] * v.y + m[5] * v.z,
                  m[6] * v.x + m[7] * v.y + m[8] * v.z);
}

// One output pixel per lane (`dovi_lane_column`): the composed luma sum at the pixel, and the composed chroma, already
// brought to every row by `dovi_chroma_420_to_422`, brought to the pixel's column by the reference horizontal 2:1
// filter (`dovi_el_h`; chroma sits on the even luma columns). Each is reconstructed to hdr_bit_depth bits
// (`dovi_reconstruct`, CCM 001 5.4.3.3), taken to the signal's [0, 1] range, converted, and written as BT.2020
// non-constant-luminance Y'CbCr, PQ, 16-bit video range (luma 4096...60160), 4:4:4, so nothing is rounded between
// the reconstruction and the still's own mapping. Whole threadgroups 32 wide, as the composition kernels.
kernel void dovi_ipt_to_bt2020(
    texture2d<ushort, access::read>        sum_y_tex     [[texture(0)]],
    texture2d<ushort, access::read>        sum_uv_tex    [[texture(1)]],
    texture2d<ushort, access::write>       out_y_tex     [[texture(2)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    constant struct DoviIptConversion&     conversion    [[buffer(4)]],
    uint2                                  grid          [[thread_position_in_grid]],
    uint                                   lane          [[thread_index_in_simdgroup]])
{
    uint x0 = grid.x - lane;
    uint2 gid = uint2(dovi_lane_column(x0, lane), grid.y);
    uint row = min(gid.y, params.bl_height - 1u);
    int column = dovi_el_column(x0, lane, dovi_chroma_size(params.bl_width));
    int2 chroma = dovi_el_h(int2(sum_uv_tex.read(uint2(uint(column), row)).rg), lane);
    if (gid.x >= params.bl_width || gid.y >= params.bl_height) {
        return;
    }
    float max_code = float(params.vdr_max);
    float3 signal = float3(float(dovi_reconstruct(int(sum_y_tex.read(gid).r), params.vdr_max)),
                           float(dovi_reconstruct(chroma.x, params.vdr_max)),
                           float(dovi_reconstruct(chroma.y, params.vdr_max))) / max_code;
    float3 offset = float3(conversion.ycc_offset[0], conversion.ycc_offset[1], conversion.ycc_offset[2]);
    float3 lms = dovi_pq_eotf(dovi_mul3(conversion.ycc_to_lms, signal - offset));
    float3 rgb = dovi_pq_oetf(max(dovi_mul3(conversion.lms_to_rgb, lms), 0.0f));
    float y = dot(rgb, float3(0.2627f, 0.6780f, 0.0593f));
    float cb = (rgb.b - y) / 1.8814f;
    float cr = (rgb.r - y) / 1.4746f;
    uint3 codes = uint3(clamp(rint(float3(4096.0f + 56064.0f * y, 32768.0f + 57344.0f * cb, 32768.0f + 57344.0f * cr)),
                              0.0f, 65535.0f));
    out_y_tex.write(ushort4(ushort(codes.x), 0, 0, 0), gid);
    out_uv_tex.write(ushort4(ushort(codes.y), ushort(codes.z), 0, 0), gid);
}

/* ============================================================================
   Layout probe
   ========================================================================= */

// Reads sentinels back out of the parameter block the host actually uploaded,
// so the Swift serialiser and this shader's struct definitions are checked
// against each other on the GPU rather than by hand. Metal has no static_assert
// and the offline metal compiler is not always installed, so slot 0 carries
// sizeof(DoviMetalParams), slots 1-35 the scalars and the last element of each
// sub-block, slots 36-95, per component, the first element of every array and every
// NLQ scalar, and slot 96 bl_chroma_loc: any offset drift or swapped neighbours
// moves a sentinel and the test fails.
kernel void dovi_layout_probe(
    constant struct DoviMetalParams& params [[buffer(0)]],
    device uint*                     out    [[buffer(1)]],
    uint                             tid    [[thread_position_in_grid]])
{
    if (tid != 0u) {
        return;
    }

    out[0] = uint(sizeof(struct DoviMetalParams));

    out[1] = params.bl_width;
    out[2] = params.bl_height;
    out[3] = params.el_width;
    out[4] = params.el_height;
    out[5] = params.target_mode;
    out[6] = params.dither_mode;
    out[7] = params.frame_index;
    out[8] = params.flags;

    out[9]  = params.poly_y.num_pivots;
    out[10] = params.poly_y.pivots[8];
    out[11] = params.poly_y.method[7];
    out[12] = params.poly_y.order[7];
    out[13] = uint(params.poly_y.coef[7][2]);
    out[14] = params.poly_y.coef_shift[7];
    out[15] = uint(params.mmr_y.mmr_constant[7]);
    out[16] = uint(params.mmr_y.coef[7][20]);
    out[17] = params.mmr_y.coef_shift;
    out[18] = uint(params.nlq_y.vdr_in_max);
    out[19] = params.nlq_y.nlq_pivots[1];

    out[20] = params.poly_cb.num_pivots;
    out[21] = params.poly_cb.coef_shift[7];
    out[22] = uint(params.mmr_cb.coef[7][20]);
    out[23] = params.mmr_cb.coef_shift;
    out[24] = params.nlq_cb.nlq_pivots[1];

    out[25] = params.poly_cr.num_pivots;
    out[26] = params.poly_cr.coef_shift[7];
    out[27] = uint(params.mmr_cr.coef[7][20]);
    out[28] = params.mmr_cr.coef_shift;
    out[29] = params.nlq_cr.nlq_pivots[1];

    out[30] = params.min_pq;
    out[31] = params.max_pq;
    out[32] = params.avg_pq;
    out[33] = params.bl_max;
    out[34] = params.vdr_max;
    out[35] = params.vdr_scale;

    // --- y: first element of every array and every NLQ scalar ---
    out[36] = params.poly_y.pivots[0];
    out[37] = params.poly_y.pivots[1];
    out[38] = params.poly_y.method[0];
    out[39] = params.poly_y.order[0];
    out[40] = uint(params.poly_y.coef[0][0]);
    out[41] = uint(params.poly_y.coef[0][1]);
    out[42] = uint(params.poly_y.coef[1][0]);
    out[43] = params.poly_y.coef_shift[0];
    out[44] = uint(params.mmr_y.mmr_constant[0]);
    out[45] = uint(params.mmr_y.coef[0][0]);
    out[46] = uint(params.mmr_y.coef[0][1]);
    out[47] = uint(params.mmr_y.coef[1][0]);
    out[48] = params.nlq_y.nlq_method;
    out[49] = uint(params.nlq_y.nlq_offset);
    out[50] = uint(params.nlq_y.nlq_scale);
    out[51] = uint(params.nlq_y.nlq_threshold);
    out[52] = params.nlq_y.nlq_shift;
    out[53] = uint(params.nlq_y.vdr_in_max);
    out[54] = params.nlq_y.nlq_pivots[0];
    out[55] = params.nlq_y.nlq_pivots[1];
    // --- cb: first element of every array and every NLQ scalar ---
    out[56] = params.poly_cb.pivots[0];
    out[57] = params.poly_cb.pivots[1];
    out[58] = params.poly_cb.method[0];
    out[59] = params.poly_cb.order[0];
    out[60] = uint(params.poly_cb.coef[0][0]);
    out[61] = uint(params.poly_cb.coef[0][1]);
    out[62] = uint(params.poly_cb.coef[1][0]);
    out[63] = params.poly_cb.coef_shift[0];
    out[64] = uint(params.mmr_cb.mmr_constant[0]);
    out[65] = uint(params.mmr_cb.coef[0][0]);
    out[66] = uint(params.mmr_cb.coef[0][1]);
    out[67] = uint(params.mmr_cb.coef[1][0]);
    out[68] = params.nlq_cb.nlq_method;
    out[69] = uint(params.nlq_cb.nlq_offset);
    out[70] = uint(params.nlq_cb.nlq_scale);
    out[71] = uint(params.nlq_cb.nlq_threshold);
    out[72] = params.nlq_cb.nlq_shift;
    out[73] = uint(params.nlq_cb.vdr_in_max);
    out[74] = params.nlq_cb.nlq_pivots[0];
    out[75] = params.nlq_cb.nlq_pivots[1];
    // --- cr: first element of every array and every NLQ scalar ---
    out[76] = params.poly_cr.pivots[0];
    out[77] = params.poly_cr.pivots[1];
    out[78] = params.poly_cr.method[0];
    out[79] = params.poly_cr.order[0];
    out[80] = uint(params.poly_cr.coef[0][0]);
    out[81] = uint(params.poly_cr.coef[0][1]);
    out[82] = uint(params.poly_cr.coef[1][0]);
    out[83] = params.poly_cr.coef_shift[0];
    out[84] = uint(params.mmr_cr.mmr_constant[0]);
    out[85] = uint(params.mmr_cr.coef[0][0]);
    out[86] = uint(params.mmr_cr.coef[0][1]);
    out[87] = uint(params.mmr_cr.coef[1][0]);
    out[88] = params.nlq_cr.nlq_method;
    out[89] = uint(params.nlq_cr.nlq_offset);
    out[90] = uint(params.nlq_cr.nlq_scale);
    out[91] = uint(params.nlq_cr.nlq_threshold);
    out[92] = params.nlq_cr.nlq_shift;
    out[93] = uint(params.nlq_cr.vdr_in_max);
    out[94] = params.nlq_cr.nlq_pivots[0];
    out[95] = params.nlq_cr.nlq_pivots[1];

    out[96] = params.bl_chroma_loc;
    out[97] = params.residual_split_x;
}

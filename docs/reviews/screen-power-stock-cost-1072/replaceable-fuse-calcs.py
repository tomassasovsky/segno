"""Reproduce the explicitly assumed S506 branch-fuse sensitivity models."""
import json, math
V = 5.25
C = 0.010
C_local = 0.000180
R_main_fuse = 0.0139
R_touch = 0.129
I2t_main = 71.8
I2t_touch = 2.78
E = 0.5 * C * V**2
local_pulse = 0.5 * C_local * V**2 / R_touch
joined = []
for R_main in (0.020, 0.050, 0.100, 0.200):
    R_parallel = R_main * R_touch / (R_main + R_touch)
    alpha_touch = R_main / (R_main + R_touch)
    panel_touch = E / R_parallel * alpha_touch**2
    # Minkowski bound for overlap of local and panel current waveforms.
    bound = (math.sqrt(panel_touch) + math.sqrt(local_pulse))**2
    joined.append(dict(R_main=R_main, R_touch=R_touch, panel_touch=panel_touch,
                       local_touch=local_pulse, combined_upper=bound,
                       fraction_typical=bound / I2t_touch))
main_drop = sum((.100,.044,.020,.1275,.020,.085,.030,.020,.060,.0694))
touch_drop = sum((.100,.044,.020,.1275,.020,.150,.005,.020,.010,.074))
result = dict(V=V,C=C,C_local=C_local,
 main_fuse_only_I2t=E/R_main_fuse,
 main_fraction_typical=E/R_main_fuse/I2t_main,
 main_half_resistance_fraction=2*E/R_main_fuse/I2t_main,
 joined=joined,
 voltage=dict(main_drop=main_drop,touch_drop=touch_drop,
              main_at_J1_4_75=4.75-main_drop,touch_at_J1_4_75=4.75-touch_drop),
 wire=[])
rho60 = 1.724e-8 * (1 + .00393 * 40)
for label, area, cases in [
 ('28AWG',.0804e-6,((1.68,120),(2.2,10),(3.2,3),(8,.3))),
 ('20AWG',.518e-6,((8.4,120),(11,10),(16,3),(40,.3)))]:
    R = rho60 * .6 / area
    heat_capacity = 8960 * area * .6 * 385
    for I,t in cases:
        result['wire'].append(dict(wire=label,current=I,seconds=t,
             loop_R_at_60C=R,loop_power=I**2*R,
             adiabatic_rise_with_fixed_initial_R=I**2*R*t/heat_capacity))

# Practical nominal-input cases: 20 cm one-way leads, 60 C copper.
common = .100 + .044 + .020 + .1275 + .020
result['practical_20cm'] = []
for name,I,awg,Rf in [('large',2.0,20,.085/3),('small',1.2,20,.085/3),('touch',.5,28,.150/.5)]:
    Rwire = 2*.2*{20:.03331,28:.2129}[awg]*1.1572
    loss = common + I*Rf + I*.01 + .020 + I*.02 + I*Rwire
    result['practical_20cm'].append(dict(path=name,nominal_input_V=5.0,loss_V=loss,load_V_before_final_termination=5.0-loss))

print(json.dumps(result,indent=2))

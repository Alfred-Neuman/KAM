#include "..\script_component.hpp"
/*
 * Author: Mazinski
 * Updates the respiratory variables 
 *
 * Arguments:
 * 0: The Unit <OBJECT>
 * 1: Heart Rate <NUMBER>
 * 2: Anerobic Pressure <NUMBER>
 * 3: Blood Gas Array <ARRAY>
 * 4: Temperature <NUMBER>
 * 5: Barometric Pressure <NUMBER>
 * 6: Opioid Depression <NUMBER>
 * 7: Time since last update <NUMBER>
 * 8: Sync value? <BOOL> 
 *
 * ReturnValue:
 * Current O2 Saturation <NUMBER>
 *
 * Example:
 * [player, 80, 0.8, [40,90,0.96,24,7.4], 37, 760, 0, 1, true] call kat_vitals_fnc_handleOxygenFunction;
 *
 * Public: No
 */

params ["_unit", "_actualHeartRate", "_anerobicPressure", "_bloodGas", "_temperature", "_baroPressure", "_opioidDepression", "_deltaT", "_syncValues"];

#define MAXIMUM_RR 40
#define HEART_RATE_CO2_MULTIPLIER 60
#define MINIMUM_VENTILATION 2000
#define PACO2_MAX_CHANGE 0.05
#define PAO2_MAX_CHANGE 0.1
#define DEFAULT_FIO2 0.21
#define MINIMUM_DEPTH 0.2

private _respiratoryRate = 0;
private _respiratoryDepression = 0;
private _demandVentilation = 0;
private _actualVentilation = 0;
private _previousCyclePaco2 = (_bloodGas select 0);
private _previousCyclePao2 = (_bloodGas select 1);

if (IN_CRDC_ARRST(_unit)) then { 
    // When in arrest, there should be no effecive breaths but still a minimum O2 demand. Zero O2 demand would mean a dead patient. Actual ventilation is 1 to prevent issues in the gas tension functions
    _demandVentilation = MINIMUM_VENTILATION;
    _respiratoryDepression = 1;
    _respiratoryRate = [0, 20] select (_unit getVariable [QEGVAR(breathing,BVMInUse), false]);
    _actualVentilation = 1;
} else {
    // Ventilatory Demand comes from Heart Rate with increase demand from PaCO2 levels 
    _demandVentilation = ((((_actualHeartRate * HEART_RATE_CO2_MULTIPLIER) / _anerobicPressure) + ((_previousCyclePaco2 - DEFAULT_PACO2) * 200)) max MINIMUM_VENTILATION);
    private _tidalVolume = GET_KAT_SURFACE_AREA(_unit);

    // Tidal Volume is modified by respiratory depth which can be supressed by opioids and pneumothroax
    private _respiratoryDepth = [((DEFAULT_RESPIRATORY_DEPTH / 10) - (_opioidDepression / 1.5)), 10] select (_unit getVariable [QEGVAR(breathing,BVMInUse), false]);
    private _tidalVolume = GET_KAT_SURFACE_AREA(_unit) * (_respiratoryDepth / 1);
    
    // Respiratory Rate Calculation
    _respiratoryRate = [((_demandVentilation / _tidalVolume)) min MAXIMUM_RR, 20] select (_unit getVariable [QEGVAR(breathing,BVMInUse), false]);

    // If respiratory rate is low due to PaCO2, it starts increasing faster to compensate
    if (_previousCyclePaco2 > 50) then { _respiratoryRate = (_respiratoryRate + ((_previousCyclePaco2 - 50) * 0.2)) min MAXIMUM_RR};

    _actualVentilation = _tidalVolume * _respiratoryRate;
};

private _paco2 = 40;

if (EGVAR(breathing,paco2Active)) then {
    // The greater the imbalance between CO2 explusion and O2 intake, the higher PaCO2 gets
    _paco2 = if ((_demandVentilation / _actualVentilation) == 1) then { _previousCyclePaco2 + (PACO2_MAX_CHANGE min (-PACO2_MAX_CHANGE max ((DEFAULT_PACO2 + ((_anerobicPressure max 1) - 1) * 150) - _previousCyclePaco2))) } else { [ _previousCyclePaco2 - (PACO2_MAX_CHANGE * _deltaT), _previousCyclePaco2 + (PACO2_MAX_CHANGE * _deltaT)] select ((_demandVentilation / _actualVentilation) > 1) };                                    
};

private _etco2 = 37;

if (IN_CRDC_ARRST(_unit)) then {
    if (alive (_unit getVariable [QACEGVAR(medical,CPR_provider), objNull])) then {
        // If CPR is being provided, EtCO2 acts as a surrogate for remaining time patient can be in cardiac arrest before death
        _etco2 = (15 + (_paco2 / 40) - (((_unit getVariable [QACEGVAR(medical_statemachine,cardiacArrestTimeLeft), 1]) max 1) / (ACEGVAR(medical_statemachine,cardiacArrestTime)) * 10)) max 1;
    } else {
        // With no CPR, there is no movement in the chest, and so there is no EtCO2
        _etco2 = 0;
    };
} else {
    // Generated ETCO2 quadratic. Ensures ETCO2 moves with Respiratory Rate and is constantly below PaCO2 
    _etco2 = (((_paco2 - 3) - ((-0.0416667 * (_respiratoryRate^2)) + (3.09167 * (_respiratoryRate))) * (_respiratoryDepth)) - DEFAULT_ETCO2) max 5;
};

private _externalPh = 0;
private _pH = 7.4;

if (EGVAR(pharma,kidneyAction)) then {
    // Extenal pH impacts from saline is included
    _externalPh = _unit getVariable [QEGVAR(pharma,externalPh), 0];

    // Adjust dissociation constant based on temperature 
    private _phConstant = ((-0.00006653 * (_temperature ^ 2)) - (0.03268 * _temperature) + 7.4);
    private _fatigue = [0, (ACEGVAR(advanced_fatigue,anFatigue) / 2)] select (ACEGVAR(advanced_fatigue,enabled));

    // pH is from the Henderson-Hasselbalch equation
    _pH = (_phConstant + log(24 / ((0.03 * _paco2)))) - ((_externalPh max 1) / 2000) - (_fatigue / 3);
};

// Fractional Oxygen when breathing normal air is 0.21, 1 when breathing 100% Oxygen, and 0 when no air is being brought into the lungs
private _fio2 = switch (true) do {
    case ((_unit getVariable [QEGVAR(airway,occluded), false]) || (_unit getVariable [QEGVAR(airway,obstruction), false])): { 
        [0, DEFAULT_FIO2] select ((_unit getVariable [QEGVAR(airway,recovery), false]) || (_unit getVariable [QEGVAR(airway,overstretch), false])) 
    };
    case ((_respiratoryRate == 0) && (EGVAR(breathing,SpO2_perfusion))): { 0 };
    case ((_unit getVariable [QEGVAR(chemical,airPoisoning), false]) || (_unit getVariable [QEGVAR(breathing,tensionpneumothorax), false]) || (_unit getVariable [QEGVAR(breathing,hemopneumothorax), false])): { 0 };
    case (_unit getVariable [QEGVAR(breathing,oxygenMaskActive), false]): { 0.95 };
    case (_unit getVariable [QEGVAR(breathing,oxygenTankConnected), false]): { 1 };
    default { DEFAULT_FIO2 };
};

// Alveolar Gas equation. PALVO2 is largely impacted by Barometric Pressure and FiO2
private _pALVo2 = ((_fio2 * (_baroPressure - 47)) - (_paco2 / _anerobicPressure)) max 1;

// PaO2 comes from ventilation shortage multipled by RBC volume
private _pao2 = (DEFAULT_PAO2 - ((DEFAULT_ECB / ((GET_BODY_FLUID(_unit) select 0) max 500)) * ((_demandVentilation - _actualVentilation) / 120)));

// PaO2 is shifted by the difference between PALVO2 and PaO2, capped by PALVO2
_pao2 = (((linearConversion[-50, 50, (_pALVo2 - _pao2), -20, 20, false]) + _pao2) min _pALVo2) max 0;

private _arrestPerfusion = [1, (1 * EGVAR(breathing,SpO2_PerfusionMultiplier))] select ((IN_CRDC_ARRST(_unit)) && (EGVAR(breathing,SpO2_perfusion)));
// PaO2 moves in controlled steps to prevent hard movements when Ventilation Demand spikes
_pao2 = if (_previousCyclePao2 != _pao2) then { ([ (_previousCyclePao2 - ((PAO2_MAX_CHANGE * EGVAR(breathing,SpO2_MultiplyNegative) * _arrestPerfusion) * _deltaT)) , (_previousCyclePao2 + ((PAO2_MAX_CHANGE * EGVAR(breathing,SpO2_MultiplyPositive)) * _deltaT))] select ((_previousCyclePao2 - _pao2) < 0)) } else { _pao2 };

// Oxy-Hemo Dissociation Curve, driven by PaO2 with shaping done by pH.
private _o2Sat = (((_pao2 max 1)^2.7 / ((25 - (((_pH / DEFAULT_PH) - 1) * 150))^2.7 + _pao2^2.7))) min 0.999;

_unit setVariable [VAR_BREATHING_RATE, (_respiratoryRate max 0), _syncValues];
_unit setVariable [VAR_BLOOD_GAS, [_paco2, _pao2, _o2Sat, 24, _pH, _etco2], _syncValues];
_unit setVariable [QGVAR(respiratoryDepth), (_respiratoryDepth max 0), _syncValues];
_o2Sat * 100

extends Resource
class_name PatientDetails

@export var patient_register: Dictionary = {}
@export var current_patient_id: String

# Function to add a patient to the register
func add_patient(hospital_id: String, patient_name: String, age: int, gender:String, stroke_time:int, dominant_hand:String, affected_hand:String, comments:String = "") -> bool:
    if hospital_id in patient_register:
        print("Patient with this hospital ID already exists!")
        return false
    patient_register[hospital_id] = {"name": patient_name, "age": age, "gender":gender, \
                                    "stroke_time":stroke_time, "dominant_hand":dominant_hand, "affected_hand":affected_hand, "comments":comments}
    return true

# Function to remove a patient from the register
func remove_patient(hospital_id: String) -> bool:
    if hospital_id in patient_register:
        patient_register.erase(hospital_id)
        return true
    print("No patient with this hospital ID found!")
    return false

# Function to get a patient's details
func get_patient(hospital_id: String) -> Dictionary:
    if hospital_id in patient_register:
        return patient_register[hospital_id]
    print("No patient with this hospital ID found!")
    return {}

# Function to list all patients
func list_all_patients() -> Array:
    var patients = []
    for hospital_id in patient_register.keys():
        patients.append({
            "hospital_id": hospital_id,
            "name": patient_register[hospital_id]["name"],
            "age": patient_register[hospital_id]["age"],
            "gender": patient_register[hospital_id]['gender'],
            "stroke_time": patient_register[hospital_id]['stroke_time'],
            "dominant_hand": patient_register[hospital_id]['dominant_hand'],
            "affected_hand": patient_register[hospital_id]['affected_hand'],
            "comments": patient_register[hospital_id]['comments'],
        })
    return patients

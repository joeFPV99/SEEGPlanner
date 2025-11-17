# DICOM → NIfTI & Electrode Extraction: High-Level Process

This script processes a root directory of patients and creates a standardized NIfTI + electrode structure.

---

## 1. Input / Output

- **Input**:  
  `INPUT_ROOT/`  
  └─ `PATxxx/` patient folders containing arbitrary DICOM subfolders

- **Output**:  
  `OUTPUT_ROOT/`  
  └─ `PATxxx/`  
        ├─ `CT_Pre/`  
        ├─ `CT_Post/`  
        ├─ `CTA/`  
        ├─ `MRI_T1/`  
        └─ `Electrode_Trajectories/`

---

## 2. Per-patient Loop

For each `PATxxx` under `INPUT_ROOT`:

1. Create `OUTPUT_ROOT/PATxxx`.
2. Recursively list all subdirectories (excluding `Electrode_Trajectories`).
3. Treat each subdirectory as a potential **DICOM series folder**.

---

## 3. Series Classification

For each series folder:

1. **Find representative DICOM**
   - Look only at files directly in that folder.
   - First file where `dcmdump` can read Modality (0008,0060) is used.

2. **Read tags from representative file**
   - `Modality` → (0008,0060)  
   - `SeriesDescription` → (0008,103E) for CT/MR/SEG

3. **Decide handling**
   - **CT** → convert (later split: CT_Pre / CT_Post / CTA)
   - **MR** → convert only if `SeriesDescription` contains `"T1"`
   - **SEG** → if `SeriesDescription` contains `"Points and Trajectories"`, treat as electrode trajectories
   - All others → **skip** (logged)

---

## 4. SEG: Electrode Trajectories (copy as .dicom)

If `Modality=SEG` and `SeriesDescription` ~ `"Points and Trajectories"`:

1. Create `PATxxx/Electrode_Trajectories/`.
2. For every DICOM file in that series:
   - Read `SegmentLabel` (0062,0005)  
     - try direct `(0062,0005)`  
     - else `(0062,0002)[0].(0062,0005)`
   - Fallback label: `"segment"` if missing.
   - Sanitize label for filenames.
   - Copy file as  
     `electrode_<label>.dcm`,  
     or `electrode_<label>_001.dcm`, `_002`, … if needed.

No NIfTI conversion is done for SEG.

---

## 5. CT / CTA / CT_Pre / CT_Post Conversion

If `Modality=CT`:

1. Ensure `SeriesDescription` is available.
2. Classify:
   - Contains `"CTA"` or `"Angio"` → **CTA**
   - Else, contains `"post"` (case-insensitive) → **CT_Post**
   - Else → **CT_Pre**
3. Build output folder:
   - `PATxxx/CTA/` or `CT_Post/` or `CT_Pre/`
4. Build filename pattern:
   - `PATxxx_<Category>_<SanitizedSeriesDescription>`
5. Ensure unique basename if multiple CT series in same category.
6. Run `dcm2niix`:
   - `-b n` (no JSON)
   - `-z y` (gzip)
   - `-f <pattern>` (filename)
   - `-o <category folder>`

---

## 6. MRI T1 Conversion

If `Modality=MR` and `SeriesDescription` contains `"T1"`:

1. Output folder: `PATxxx/MRI_T1/`
2. Filename: `PATxxx_MRI_T1_<SanitizedSeriesDescription>`
3. Ensure uniqueness.
4. Convert with `dcm2niix` (same options as CT).

---

## 7. Final Logging

For each patient:

- Logs every:
  - Entered series (converted or SEG copied)
  - Skipped series (with Modality + SeriesDescription)
- Ends with:

```text
* Completed patient: PATxxx *
=========================================
All conversions complete.
NIfTI files saved under: OUTPUT_ROOT
=========================================
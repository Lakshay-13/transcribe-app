import streamlit as st
import tempfile
import os
import time
from moviepy.video.io.VideoFileClip import VideoFileClip  # Latest MoviePy import
from pydub import AudioSegment
from openai import OpenAI
import zipfile
import io

# Configure the page (default layout is centered)
st.set_page_config(page_title="Transcribe App")

# Set the OpenAI API key from st.secrets.
os.environ['OPENAI_API_KEY'] = st.secrets["OPENAI_API_KEY"]

# Initialize session state for transcripts and visibility toggle.
if "transcripts" not in st.session_state:
    st.session_state.transcripts = {}  # Will hold {file_index: transcript_text}
if "show_transcript" not in st.session_state:
    st.session_state.show_transcript = True

def cleanup_files(tmp_paths):
    """Remove all files in the list tmp_paths."""
    for path in tmp_paths:
        try:
            if os.path.exists(path):
                os.remove(path)
        except Exception as e:
            st.warning(f"Could not delete {path}: {e}")

def transcribe_audio_openai(audio_path):
    """
    Uses OpenAI's Whisper API (via the new client interface) to transcribe the given audio file.
    Uses the latest format:
        from openai import OpenAI
        client = OpenAI()
        transcription = client.audio.transcriptions.create(model="whisper-1", file=audio_file)
    Returns transcription.text.
    """
    client = OpenAI()
    with open(audio_path, "rb") as audio_file:
        transcription = client.audio.transcriptions.create(
            model="whisper-1",
            file=audio_file,
            response_format="text"
        )
    return transcription

def transcribe_large_audio(audio_path, chunk_length_ms=10*60*1000):
    """
    Loads the audio file using pydub. If the audio duration exceeds chunk_length_ms,
    splits it into chunks and transcribes each chunk separately, joining them with a newline.
    Otherwise, transcribes the entire audio file.
    """
    audio = AudioSegment.from_file(audio_path)
    duration_ms = len(audio)
    transcripts = []
    if duration_ms > chunk_length_ms:
        num_chunks = (duration_ms // chunk_length_ms) + (1 if duration_ms % chunk_length_ms > 0 else 0)
        for i in range(num_chunks):
            start_ms = i * chunk_length_ms
            end_ms = min((i + 1) * chunk_length_ms, duration_ms)
            with st.spinner(f"Transcribing chunk {i+1} of {num_chunks}..."):
                chunk = audio[start_ms:end_ms]
                with tempfile.NamedTemporaryFile(delete=False, suffix=".mp3") as seg_file:
                    seg_file_path = seg_file.name
                chunk.export(seg_file_path, format="mp3")
                chunk_transcript = transcribe_audio_openai(seg_file_path)
                transcripts.append(chunk_transcript.strip())
                os.remove(seg_file_path)
    else:
        with st.spinner("Transcribing audio..."):
            transcripts.append(transcribe_audio_openai(audio_path).strip())
    return "\n".join(transcripts)

def process_file(file_obj, index):
    """
    Saves the uploaded file, converts it if necessary, and returns the transcript.
    Returns a tuple (transcript, list_of_temp_file_paths).
    """
    temp_files = []
    file_ext = os.path.splitext(file_obj.name)[1].lower()
    with tempfile.NamedTemporaryFile(delete=False, suffix=file_ext) as tmp_file:
        tmp_file.write(file_obj.read())
        tmp_path = tmp_file.name
    temp_files.append(tmp_path)
    
    # If file is MP4, convert to MP3.
    if file_ext == ".mp4":
        with st.spinner(f"Converting file {file_obj.name} (file {index+1}) from MP4 to MP3..."):
            try:
                video_clip = VideoFileClip(tmp_path)
                with tempfile.NamedTemporaryFile(delete=False, suffix=".mp3") as audio_temp:
                    audio_path = audio_temp.name
                video_clip.audio.write_audiofile(audio_path, logger=None)
                video_clip.close()
                temp_files.append(audio_path)
            except Exception as e:
                st.error(f"Error during conversion of {file_obj.name}: {e}")
                cleanup_files(temp_files)
                return None, temp_files
    else:
        audio_path = tmp_path
    
    # Transcribe the (converted) audio file.
    transcript = transcribe_large_audio(audio_path)
    return transcript, temp_files

def zip_transcripts(transcripts_dict, base_filename, start):
    """
    Given a dictionary mapping indices to transcript text, create an in-memory zip file
    where each transcript is stored as base_filename_1.txt, base_filename_2.txt, etc.
    Returns the bytes of the zip file.
    """
    mem_zip = io.BytesIO()
    with zipfile.ZipFile(mem_zip, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        for idx, transcript in transcripts_dict.items():
            file_name = f"{base_filename}_{start+idx}.txt"
            zf.writestr(file_name, transcript)
    mem_zip.seek(0)
    return mem_zip.read()

def main():
    st.title("Transcription with OpenAI Whisper")
    # st.write(
    #     """
    #     Upload one or more **MP3** or **MP4** files. If an MP4 is uploaded, it will be converted to MP3 before transcription.
    #     Click **Start Transcribing** to begin processing. Once complete, you can choose to show/hide the transcript and download it.
    #     """
    # )
    
    # st.info(
    #     "If you need to upload files larger than 200MB, update your `.streamlit/config.toml` with:\n\n"
    #     "```\n[server]\nmaxUploadSize = 500\n```"
    # )
    
    # Upload multiple files.
    uploaded_files = st.file_uploader("Choose one or more MP3 or MP4 files", type=["mp3", "mp4"], accept_multiple_files=True)
    
    # Text input for the base download filename (shown only if at least one file is uploaded).
    if uploaded_files:
        base_filename = st.text_input("Enter base filename for the transcript(s) (without extension):", "transcript")
        start = st.text_input("Enter the starting suffix for the filenames:", "1")
        start = int(start)
    else:
        base_filename = "transcript"
    
    # Create a row with three buttons: Start Transcribing, Show/Hide Transcript, Download Transcript.
    col1, col2, col3 = st.columns(3)
    
    # Button to start transcription.
    if col1.button("Start Transcribing"):
        transcripts = {}
        temp_files_all = []
        for i, file_obj in enumerate(uploaded_files):
            with st.spinner(f"Processing file {i+1} of {len(uploaded_files)}..."):
                transcript, temp_files = process_file(file_obj, i)
                temp_files_all.extend(temp_files)
                if transcript is None:
                    transcripts[i] = ""
                else:
                    transcripts[i] = transcript
        st.session_state.transcripts = transcripts
        st.success("Transcription complete!")
    
    # Button to toggle show/hide transcript.
    if col2.button("Show/Hide Transcript"):
        st.session_state.show_transcript = not st.session_state.show_transcript
    
    # Prepare download button.
    if col3.button("Download Transcript"):
        if st.session_state.transcripts:
            if len(st.session_state.transcripts) == 1:
                # Single file: download transcript as text.
                transcript_text = next(iter(st.session_state.transcripts.values()))
                st.download_button(
                    label="Download Transcript",
                    data=transcript_text,
                    file_name=f"{base_filename}.txt",
                    mime="text/plain"
                )
            else:
                # Multiple files: zip the transcript files.
                zip_bytes = zip_transcripts(st.session_state.transcripts, base_filename, start)
                st.download_button(
                    label="Download Transcripts (Zip)",
                    data=zip_bytes,
                    file_name=f"{base_filename}.zip",
                    mime="application/zip"
                )
        else:
            st.warning("No transcripts available to download.")
    
    # Show transcript if available and if the toggle is set to show.
    if st.session_state.get("transcripts") and st.session_state.show_transcript:
        st.subheader("Transcripts")
        # If multiple files, display each transcript in its own text area.
        if len(st.session_state.transcripts) == 1:
            transcript_text = next(iter(st.session_state.transcripts.values()))
            st.text_area("Transcript", value=transcript_text, height=300)
        else:
            for i, transcript in st.session_state.transcripts.items():
                st.text_area(f"Transcript for File {i+1}", value=transcript, height=300)
    
if __name__ == "__main__":
    main()

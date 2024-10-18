import streamlit as st
import os
from io import BytesIO
from dotenv import load_dotenv
load_dotenv()  # Load environment variables from .env
import assemblyai as aai
from pydub import AudioSegment

# Set AssemblyAI API key
aai.settings.api_key = os.getenv('ASSEMBLYAI_API_KEY')

# Function to convert m4a (or other formats) to wav
def convert_m4a_to_wav(uploaded_file):
    audio = AudioSegment.from_file(uploaded_file, format="m4a")  # Process uploaded file directly
    output = BytesIO()  # Output to a BytesIO object
    audio.export(output, format="wav")  # Export the converted audio
    output.seek(0)  # Reset pointer to the start of the BytesIO object
    return output

# Transcription function using AssemblyAI
def transcribe_audio(file, speakers_count):
    config = aai.TranscriptionConfig(speaker_labels=True, speakers_expected=speakers_count)
    transcript = aai.Transcriber().transcribe(file, config)
    text = ''.join(f"Speaker {utterance.speaker}: {utterance.text} \n" for utterance in transcript.utterances)
    return text

def main():
    st.title("Audio Transcription App")
    st.write("Upload an audio file to transcribe it into text.")
    
    # File uploader widget
    audio_file = st.file_uploader("Choose an audio file", type=["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm"])

    # Number input for expected number of speakers
    speakers_count = st.number_input("Enter the number of expected speakers", min_value=1, max_value=10, value=2)

    if audio_file is not None:
        # Show some info about the file
        st.audio(audio_file, format='audio/m4a')  # Streamlit can play m4a directly
        
        # Convert and transcribe the uploaded audio file
        if st.button("Transcribe"):
            with st.spinner("Transcribing..."):
                # Convert the file if it's in m4a format
                if audio_file.type == "audio/m4a":
                    converted_file = convert_m4a_to_wav(audio_file)
                else:
                    converted_file = audio_file  # If it's already a wav or supported format

                # Transcribe the audio with the specified number of speakers
                transcription = transcribe_audio(converted_file, speakers_count)
                st.success("Transcription completed!")
                st.text_area("Transcribed Text", transcription, height=300)

                # Option to download the transcription
                st.download_button(
                    label="Download Transcript",
                    data=transcription,
                    file_name="transcription.txt",
                    mime="text/plain"
                )

if __name__ == '__main__':
    main()

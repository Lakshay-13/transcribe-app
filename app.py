import streamlit as st
import os
from io import StringIO

from dotenv import load_dotenv
load_dotenv()  # Load environment variables from .env
from openai import OpenAI
client = OpenAI()
# # Initialize OpenAI API key
# openai.api_key = os.getenv('OPENAI_API_KEY')  # Set your API key in environment variables or hardcode it.

def transcribe_audio(file):
    # Send audio file to OpenAI Whisper API for transcription
    transcript = client.audio.transcriptions.create(
        model="whisper-1",
        file=file
    )
    return transcript.text

def main():
    st.title("Audio Transcription App using OpenAI Whisper")
    st.write("Upload an audio file to transcribe it into text.")
    
    # File uploader widget
    audio_file = st.file_uploader("Choose an audio file", type=["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm"])

    if audio_file is not None:
        # Show some info about the file
        st.audio(audio_file, format='audio/wav')
        
        # Transcribe the uploaded audio file
        if st.button("Transcribe"):
            with st.spinner("Transcribing..."):
                transcription = transcribe_audio(audio_file)
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

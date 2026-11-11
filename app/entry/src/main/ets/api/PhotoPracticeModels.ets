export type PhotoPracticeType = 'calculation' | 'written';

export interface PhotoPracticeExercise {
  exerciseId: string;
  type: PhotoPracticeType;
  title: string;
  stem: string;
}

export interface PhotoPracticeQuery {
  knowledgePointName: string;
  knowledgePointId?: string;
  courseName: string;
  type: PhotoPracticeType;
  previousExerciseId?: string;
}

export interface PhotoPracticeSubmission {
  image: string;
  review?: boolean;
}

export interface PhotoPracticeCompletion {
  attemptId?: string;
  transcript?: string;
  outcome?: 'unknown';
}

export interface PhotoPracticeWrongBookRequest {
  attemptId: string;
}

export interface PhotoPracticeCriterion {
  id: string;
  label: string;
  points: number;
  maxPoints: number;
  feedback: string;
}

export interface PhotoPracticeGrade {
  exerciseId: string;
  status: 'retake' | 'review' | 'graded' | 'unknown';
  attemptId?: string;
  knowledgePointId?: string;
  knowledgePointName?: string;
  courseName?: string;
  message?: string;
  transcript?: string;
  criteria?: PhotoPracticeCriterion[];
  score?: number;
  maxScore?: number;
  explanation?: string;
}

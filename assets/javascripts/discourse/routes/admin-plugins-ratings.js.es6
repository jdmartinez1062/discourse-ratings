import DiscourseRoute from "discourse/routes/discourse";
import { A } from "@ember/array";
import { all } from "rsvp";
import RatingType from '../models/rating-type';
import RatingObject from '../models/rating-object';

export default DiscourseRoute.extend({
  model() {
    return RatingType.all();
  },
  
  afterModel(model) {
    return all([
      this._typesFor('category'),
      this._typesFor('tag')
    ])
  },
  
  setupController(controller, model) {
    controller.setProperties({
      ratingTypes: A(model.map(t => RatingType.create(t))),
      categoryTypes: A(this.categoryTypes),
      tagTypes: A(this.tagTypes)
    });
  },
  
  _typesFor(object, model) {
    return RatingObject.all(object).then(result => {
      this.set(`${object}Types`, result);
    })
  },
  
  actions: {
    refresh() {
      this.refresh();
    }
  }
})